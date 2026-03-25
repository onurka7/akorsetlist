const admin = require("firebase-admin");
const logger = require("firebase-functions/logger");
const {defineSecret} = require("firebase-functions/params");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();
const APPLE_SHARED_SECRET = defineSecret("APPLE_SHARED_SECRET");

const USERS_COLLECTION = "users";
const PRIVATE_RECEIPT_COLLECTION = "_private";
const PRIVATE_RECEIPT_DOC = "app_store_receipt";

const APP_STORE_PRODUCTION_URL = "https://buy.itunes.apple.com/verifyReceipt";
const APP_STORE_SANDBOX_URL = "https://sandbox.itunes.apple.com/verifyReceipt";

const ANNUAL_PRODUCT_IDS = new Set([
  "annual_plan_100_try",
  "com.gitar.akorlist.annual_plan_100_try",
]);

exports.verifyAppleSubscriptionReceipt = onCall(
    {
      region: "europe-west1",
      secrets: [APPLE_SHARED_SECRET],
    },
    async (request) => {
      const uid = request.auth?.uid;
      if (!uid) {
        throw new HttpsError("unauthenticated", "Kullanici girisi gerekli.");
      }

      const receiptData = `${request.data?.receiptData || ""}`.trim();
      const productId = `${request.data?.productId || ""}`.trim();
      const transactionId = `${request.data?.transactionId || ""}`.trim();

      if (!receiptData) {
        throw new HttpsError("invalid-argument", "Receipt verisi zorunlu.");
      }
      if (productId && !ANNUAL_PRODUCT_IDS.has(productId)) {
        throw new HttpsError("invalid-argument", "Bilinmeyen subscription urunu.");
      }

      const verification = await verifyReceiptWithApple({
        receiptData,
        sharedSecret: APPLE_SHARED_SECRET.value(),
      });
      const membership = extractMembershipSnapshot(verification.payload);

      await persistMembership(uid, {
        ...membership,
        latestReceiptData: verification.payload.latest_receipt || receiptData,
        productIdHint: productId || null,
        transactionIdHint: transactionId || null,
        environment: verification.environment,
      });

      return serializeMembership(membership);
    },
);

exports.refreshAppleSubscriptionStatus = onCall(
    {
      region: "europe-west1",
      secrets: [APPLE_SHARED_SECRET],
    },
    async (request) => {
      const uid = request.auth?.uid;
      if (!uid) {
        throw new HttpsError("unauthenticated", "Kullanici girisi gerekli.");
      }

      const receiptSnapshot = await privateReceiptRef(uid).get();
      const latestReceiptData = receiptSnapshot.data()?.latestReceiptData;

      if (!latestReceiptData) {
        const userDoc = await userRef(uid).get();
        const currentData = userDoc.data() || {};
        const fallbackMembership = {
          plan: currentData.plan || "free",
          subscriptionStatus: currentData.subscriptionStatus || "none",
          subscriptionPlatform: currentData.subscriptionPlatform || null,
          subscriptionProductId: currentData.subscriptionProductId || null,
          originalTransactionId: currentData.originalTransactionId || null,
          subscriptionExpiresAtMs: currentData.subscriptionExpiresAt?.toMillis?.() || null,
          subscriptionLastVerifiedAtMs:
            currentData.subscriptionLastVerifiedAt?.toMillis?.() || null,
        };
        return fallbackMembership;
      }

      const verification = await verifyReceiptWithApple({
        receiptData: latestReceiptData,
        sharedSecret: APPLE_SHARED_SECRET.value(),
      });
      const membership = extractMembershipSnapshot(verification.payload);

      await persistMembership(uid, {
        ...membership,
        latestReceiptData: verification.payload.latest_receipt || latestReceiptData,
        environment: verification.environment,
      });

      return serializeMembership(membership);
    },
);

exports.expireAppleSubscriptions = onSchedule(
    {
      region: "europe-west1",
      schedule: "every 6 hours",
      timeZone: "Europe/Istanbul",
      secrets: [APPLE_SHARED_SECRET],
    },
    async () => {
      const annualUsers = await db
          .collection(USERS_COLLECTION)
          .where("plan", "==", "annual")
          .get();

      logger.info(`Annual abonelik kontrolu: ${annualUsers.size} kullanici`);

      for (const doc of annualUsers.docs) {
        const uid = doc.id;
        const data = doc.data() || {};
        const receiptSnapshot = await privateReceiptRef(uid).get();
        const latestReceiptData = receiptSnapshot.data()?.latestReceiptData;

        try {
          if (latestReceiptData) {
            const verification = await verifyReceiptWithApple({
              receiptData: latestReceiptData,
              sharedSecret: APPLE_SHARED_SECRET.value(),
            });
            const membership = extractMembershipSnapshot(verification.payload);
            await persistMembership(uid, {
              ...membership,
              latestReceiptData:
                verification.payload.latest_receipt || latestReceiptData,
              environment: verification.environment,
            });
            continue;
          }

          const expiresAt = data.subscriptionExpiresAt?.toDate?.();
          if (expiresAt && expiresAt.getTime() <= Date.now()) {
            await downgradeToFree(uid, data);
          }
        } catch (error) {
          logger.error(`Subscription cron hatasi uid=${uid}`, error);
        }
      }
    },
);

async function verifyReceiptWithApple({receiptData, sharedSecret}) {
  let payload = await postReceipt(receiptData, sharedSecret, APP_STORE_PRODUCTION_URL);
  let environment = "Production";

  if (payload.status === 21007) {
    payload = await postReceipt(receiptData, sharedSecret, APP_STORE_SANDBOX_URL);
    environment = "Sandbox";
  }

  if (payload.status !== 0) {
    throw new HttpsError(
        "failed-precondition",
        `Apple receipt verification failed: ${payload.status}`,
    );
  }

  return {payload, environment};
}

async function postReceipt(receiptData, sharedSecret, url) {
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      "receipt-data": receiptData,
      "password": sharedSecret,
      "exclude-old-transactions": true,
    }),
  });

  if (!response.ok) {
    throw new HttpsError(
        "unavailable",
        `Apple receipt endpoint failed: ${response.status}`,
    );
  }

  return response.json();
}

function extractMembershipSnapshot(payload) {
  const latestTransactions = [
    ...(Array.isArray(payload.latest_receipt_info) ? payload.latest_receipt_info : []),
    ...(Array.isArray(payload.receipt?.in_app) ? payload.receipt.in_app : []),
  ].filter((item) => ANNUAL_PRODUCT_IDS.has(item.product_id));

  latestTransactions.sort((a, b) => {
    const aMs = Number(a.expires_date_ms || 0);
    const bMs = Number(b.expires_date_ms || 0);
    return bMs - aMs;
  });

  const transaction = latestTransactions[0];
  if (!transaction) {
    return {
      plan: "free",
      subscriptionStatus: "none",
      subscriptionPlatform: "app_store",
      subscriptionProductId: null,
      originalTransactionId: null,
      subscriptionExpiresAtMs: null,
      subscriptionLastVerifiedAtMs: Date.now(),
    };
  }

  const expiresAtMs = Number(transaction.expires_date_ms || 0) || null;
  const gracePeriodExpiresAtMs =
    Number(transaction.grace_period_expires_date_ms || 0) || null;
  const now = Date.now();

  let subscriptionStatus = "expired";
  if (transaction.cancellation_date_ms) {
    subscriptionStatus = "cancelled";
  } else if (gracePeriodExpiresAtMs && gracePeriodExpiresAtMs > now) {
    subscriptionStatus = "grace_period";
  } else if (`${transaction.is_in_billing_retry_period || ""}` === "1") {
    subscriptionStatus = "billing_retry";
  } else if (expiresAtMs && expiresAtMs > now) {
    subscriptionStatus = "active";
  }

  return {
    plan: subscriptionStatus === "active" || subscriptionStatus === "grace_period" ?
      "annual" :
      "free",
    subscriptionStatus,
    subscriptionPlatform: "app_store",
    subscriptionProductId: transaction.product_id || null,
    originalTransactionId: transaction.original_transaction_id || null,
    subscriptionExpiresAtMs: expiresAtMs,
    subscriptionLastVerifiedAtMs: now,
  };
}

async function persistMembership(uid, membership) {
  const now = admin.firestore.FieldValue.serverTimestamp();
  const expiresAt = membership.subscriptionExpiresAtMs ?
    admin.firestore.Timestamp.fromMillis(membership.subscriptionExpiresAtMs) :
    null;
  const lastVerifiedAt = membership.subscriptionLastVerifiedAtMs ?
    admin.firestore.Timestamp.fromMillis(membership.subscriptionLastVerifiedAtMs) :
    admin.firestore.FieldValue.serverTimestamp();

  await userRef(uid).set({
    plan: membership.plan,
    subscriptionStatus: membership.subscriptionStatus,
    subscriptionPlatform: membership.subscriptionPlatform || "app_store",
    subscriptionProductId: membership.subscriptionProductId || membership.productIdHint || null,
    originalTransactionId:
      membership.originalTransactionId || membership.transactionIdHint || null,
    subscriptionExpiresAt: expiresAt,
    subscriptionLastVerifiedAt: lastVerifiedAt,
    subscriptionEnvironment: membership.environment || null,
    updatedAt: now,
  }, {merge: true});

  if (membership.latestReceiptData) {
    await privateReceiptRef(uid).set({
      latestReceiptData: membership.latestReceiptData,
      updatedAt: now,
    }, {merge: true});
  }
}

async function downgradeToFree(uid, userData) {
  await userRef(uid).set({
    plan: "free",
    subscriptionStatus: "expired",
    subscriptionLastVerifiedAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    subscriptionPlatform: userData.subscriptionPlatform || "app_store",
    subscriptionProductId: userData.subscriptionProductId || null,
    originalTransactionId: userData.originalTransactionId || null,
  }, {merge: true});
}

function serializeMembership(membership) {
  return {
    plan: membership.plan,
    subscriptionStatus: membership.subscriptionStatus,
    subscriptionPlatform: membership.subscriptionPlatform || null,
    subscriptionProductId: membership.subscriptionProductId || null,
    originalTransactionId: membership.originalTransactionId || null,
    subscriptionExpiresAtMs: membership.subscriptionExpiresAtMs || null,
    subscriptionExpiresAtIso: membership.subscriptionExpiresAtMs ?
      new Date(membership.subscriptionExpiresAtMs).toISOString() :
      null,
    subscriptionLastVerifiedAtMs:
      membership.subscriptionLastVerifiedAtMs || Date.now(),
    subscriptionLastVerifiedAtIso:
      new Date(
          membership.subscriptionLastVerifiedAtMs || Date.now(),
      ).toISOString(),
  };
}

function userRef(uid) {
  return db.collection(USERS_COLLECTION).doc(uid);
}

function privateReceiptRef(uid) {
  return userRef(uid)
      .collection(PRIVATE_RECEIPT_COLLECTION)
      .doc(PRIVATE_RECEIPT_DOC);
}
