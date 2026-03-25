import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';

const List<String> kAnnualPlanProductIds = <String>[
  'annual_plan_100_try',
  'com.gitar.akorlist.annual_plan_100_try',
];

enum PurchaseFlowResult {
  success,
  restored,
  cancelled,
  unavailable,
  productNotFound,
  timeout,
  failed,
}

class PurchaseService {
  PurchaseService._();

  static final PurchaseService instance = PurchaseService._();

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;

  bool _initialized = false;
  bool _available = false;
  ProductDetails? _annualProduct;
  Completer<PurchaseFlowResult>? _pendingCompleter;
  PurchaseDetails? _resolvedPurchase;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    _available = await _iap.isAvailable();
    if (!_available) return;

    await _loadProducts();
    _purchaseSub = _iap.purchaseStream.listen(
      _onPurchaseUpdated,
      onError: (_) => _resolvePending(PurchaseFlowResult.failed),
    );
  }

  Future<void> _loadProducts() async {
    final response = await _iap.queryProductDetails(
      kAnnualPlanProductIds.toSet(),
    );
    if (response.productDetails.isEmpty) {
      _annualProduct = null;
      return;
    }
    for (final id in kAnnualPlanProductIds) {
      final match = response.productDetails.where((p) => p.id == id);
      if (match.isNotEmpty) {
        _annualProduct = match.first;
        return;
      }
    }
    _annualProduct = response.productDetails.first;
  }

  ProductDetails? get annualProduct => _annualProduct;

  PurchaseDetails? takeResolvedPurchase() {
    final purchase = _resolvedPurchase;
    _resolvedPurchase = null;
    return purchase;
  }

  Future<PurchaseFlowResult> buyAnnualPlan() async {
    await initialize();
    if (!_available) return PurchaseFlowResult.unavailable;

    if (_annualProduct == null) {
      await _loadProducts();
      if (_annualProduct == null) return PurchaseFlowResult.productNotFound;
    }

    if (_pendingCompleter != null) return PurchaseFlowResult.failed;

    final completer = Completer<PurchaseFlowResult>();
    _pendingCompleter = completer;

    final started = await _iap.buyNonConsumable(
      purchaseParam: PurchaseParam(productDetails: _annualProduct!),
    );
    if (!started) {
      _resolvePending(PurchaseFlowResult.failed);
    }

    final result = await completer.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () => PurchaseFlowResult.timeout,
    );
    _pendingCompleter = null;
    return result;
  }

  Future<PurchaseFlowResult> restoreAnnualPlan() async {
    await initialize();
    if (!_available) return PurchaseFlowResult.unavailable;

    if (_pendingCompleter != null) return PurchaseFlowResult.failed;

    final completer = Completer<PurchaseFlowResult>();
    _pendingCompleter = completer;

    await _iap.restorePurchases();

    final result = await completer.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () => PurchaseFlowResult.timeout,
    );
    _pendingCompleter = null;
    return result;
  }

  void _onPurchaseUpdated(List<PurchaseDetails> updates) {
    for (final purchase in updates) {
      if (!kAnnualPlanProductIds.contains(purchase.productID)) {
        if (purchase.pendingCompletePurchase) {
          _iap.completePurchase(purchase);
        }
        continue;
      }

      switch (purchase.status) {
        case PurchaseStatus.pending:
          continue;
        case PurchaseStatus.purchased:
          _resolvedPurchase = purchase;
          _resolvePending(PurchaseFlowResult.success);
          break;
        case PurchaseStatus.restored:
          _resolvedPurchase = purchase;
          _resolvePending(PurchaseFlowResult.restored);
          break;
        case PurchaseStatus.canceled:
          _resolvePending(PurchaseFlowResult.cancelled);
          break;
        case PurchaseStatus.error:
          final code = purchase.error?.code ?? '';
          if (code.toLowerCase().contains('purchase_cancelled') ||
              code.toLowerCase().contains('canceled')) {
            _resolvePending(PurchaseFlowResult.cancelled);
          } else {
            _resolvePending(PurchaseFlowResult.failed);
          }
          break;
      }

      if (purchase.pendingCompletePurchase) {
        _iap.completePurchase(purchase);
      }
    }
  }

  void _resolvePending(PurchaseFlowResult result) {
    final completer = _pendingCompleter;
    if (completer == null || completer.isCompleted) return;
    completer.complete(result);
  }

  Future<void> dispose() async {
    await _purchaseSub?.cancel();
    _purchaseSub = null;
    _pendingCompleter = null;
    _resolvedPurchase = null;
    _initialized = false;
  }
}
