import 'package:cloud_functions/cloud_functions.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../models/membership_profile.dart';

class SubscriptionSyncService {
  SubscriptionSyncService._();

  static final SubscriptionSyncService instance = SubscriptionSyncService._();

  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  Future<MembershipProfile> verifyAppleSubscriptionPurchase(
    PurchaseDetails purchase,
  ) async {
    final receiptData = purchase.verificationData.serverVerificationData;
    if (receiptData.isEmpty) {
      throw Exception('Apple receipt verisi bos geldi.');
    }

    final callable = _functions.httpsCallable('verifyAppleSubscriptionReceipt');
    final response = await callable.call(<String, dynamic>{
      'receiptData': receiptData,
      'productId': purchase.productID,
      'transactionId': purchase.purchaseID,
    });

    return MembershipProfile.fromFunctionResult(
      Map<dynamic, dynamic>.from(response.data as Map),
    );
  }

  Future<MembershipProfile> refreshAppleSubscriptionStatus() async {
    final callable = _functions.httpsCallable('refreshAppleSubscriptionStatus');
    final response = await callable.call();
    return MembershipProfile.fromFunctionResult(
      Map<dynamic, dynamic>.from(response.data as Map),
    );
  }
}
