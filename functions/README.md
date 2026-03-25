# App Store Subscription Backend

Bu klasor Firebase Functions uzerinden Apple receipt dogrulamasi yapar.

## Gerekli kurulum

1. `cd functions`
2. `npm install`
3. `firebase login`
4. `firebase use <firebase-project-id>`
5. `firebase functions:secrets:set APPLE_SHARED_SECRET`
6. `firebase deploy --only functions`

## Secret degeri nedir

`APPLE_SHARED_SECRET` degeri App Store Connect icindeki app-specific shared secret olmalidir.

Yol:

1. App Store Connect
2. Uygulama sec
3. Subscription veya In-App Purchase ayarlari
4. App-Specific Shared Secret olustur / kopyala

## Beklenen urun ID

Kod su product ID'leri kabul eder:

- `annual_plan_100_try`
- `com.gitar.akorlist.annual_plan_100_try`

App Store Connect'teki yillik abonelik urunun bunlardan biriyle eslesmesi gerekir.

## Fonksiyonlar

- `verifyAppleSubscriptionReceipt`
  Satin alma veya restore sonrasi Apple receipt dogrular.
- `refreshAppleSubscriptionStatus`
  Uygulama acilisinda son kayitli receipt ile durumu tazeler.
- `expireAppleSubscriptions`
  Her 6 saatte bir aktif kullanicilari kontrol eder ve suresi biteni `free` yapar.
