import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

class PlayVipBilling {
  PlayVipBilling(this.productId, this.onOwnershipChanged) {
    _play.purchaseStream.listen(
      _onPurchaseUpdates,
      onError: (Object _) {
        _finishCheckout();
      },
    );
  }

  final String productId;
  final Future<void> Function(bool owned) onOwnershipChanged;
  final InAppPurchase _play = InAppPurchase.instance;
  static const _requestTimeout = Duration(seconds: 15);
  Future<void> _ownershipQueue = Future<void>.value();
  Completer<bool>? _checkout;

  Future<ProductDetails?> _product() async {
    if (!await _play.isAvailable().timeout(_requestTimeout)) return null;
    final response = await _play
        .queryProductDetails({productId})
        .timeout(_requestTimeout);
    if (response.error != null) throw StateError(response.error!.message);
    return response.productDetails.isEmpty
        ? null
        : response.productDetails.first;
  }

  Future<String?> price() async {
    try {
      return (await _product())?.price;
    } catch (_) {
      return null;
    }
  }

  Future<bool> purchase(String id) async {
    if (id != productId || _checkout != null) return false;
    final checkout = Completer<bool>();
    _checkout = checkout;
    try {
      final product = await _product();
      if (product == null) return false;
      // Attach the timeout before launching Play, which can emit immediately.
      final result = checkout.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () => false,
      );
      if (!await _play
          .buyNonConsumable(
            purchaseParam: PurchaseParam(productDetails: product),
          )
          .timeout(_requestTimeout)) {
        _finishCheckout();
      }
      return await result;
    } finally {
      if (identical(_checkout, checkout)) _checkout = null;
    }
  }

  Future<Set<String>> restore() async =>
      await _refreshOwnership() ? {productId} : <String>{};

  Future<bool> _refreshOwnership({bool preserveOnEmpty = false}) {
    final result = _ownershipQueue.then((_) async {
      final android = _play
          .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
      final response = await android.queryPastPurchases().timeout(
        _requestTimeout,
      );
      if (response.error != null) throw StateError(response.error!.message);
      final purchases = response.pastPurchases.where(
        (purchase) =>
            purchase.productID == productId &&
            (purchase.status == PurchaseStatus.purchased ||
                purchase.status == PurchaseStatus.restored),
      );
      final owned = purchases.isNotEmpty;
      if (owned || !preserveOnEmpty) await onOwnershipChanged(owned);
      for (final purchase in purchases) {
        if (purchase.pendingCompletePurchase) {
          await _play.completePurchase(purchase).timeout(_requestTimeout);
        }
      }
      return owned;
    });
    _ownershipQueue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _onPurchaseUpdates(List<PurchaseDetails> updates) async {
    final vip = updates.where((purchase) => purchase.productID == productId);
    if (vip.any(
      (purchase) =>
          purchase.error == null &&
          (purchase.status == PurchaseStatus.purchased ||
              purchase.status == PurchaseStatus.restored),
    )) {
      try {
        _finishCheckout(owned: await _refreshOwnership(preserveOnEmpty: true));
      } catch (_) {
        _finishCheckout();
      }
    } else if (vip.isNotEmpty ||
        updates.any(
          (purchase) =>
              purchase.productID.isEmpty &&
              (purchase.status == PurchaseStatus.error ||
                  purchase.status == PurchaseStatus.canceled),
        )) {
      _finishCheckout();
    }
  }

  void _finishCheckout({bool owned = false}) {
    final checkout = _checkout;
    if (checkout == null || checkout.isCompleted) return;
    checkout.complete(owned);
  }
}
