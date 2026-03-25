import 'package:flutter/material.dart';

import '../models/membership_plan.dart';
import '../services/purchase_service.dart';
import '../state/membership_state.dart';

class PlanSelectionScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback? onCompleted;
  final bool allowClose;

  const PlanSelectionScreen({
    super.key,
    required this.isDarkMode,
    this.onCompleted,
    this.allowClose = false,
  });

  @override
  State<PlanSelectionScreen> createState() => _PlanSelectionScreenState();
}

class _PlanSelectionScreenState extends State<PlanSelectionScreen> {
  bool _busy = false;

  Future<void> _selectFree() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await MembershipState.instance.selectPlan(MembershipPlan.free);
      widget.onCompleted?.call();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _buyAnnual() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await PurchaseService.instance.buyAnnualPlan();
      if (!mounted) return;

      switch (result) {
        case PurchaseFlowResult.success:
        case PurchaseFlowResult.restored:
          await MembershipState.instance.selectPlan(MembershipPlan.annual);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Yıllık plan aktif edildi.')),
          );
          widget.onCompleted?.call();
          return;
        case PurchaseFlowResult.cancelled:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Satın alma iptal edildi.')),
          );
          return;
        case PurchaseFlowResult.productNotFound:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'App Store ürünü bulunamadı. Ürün ID kontrol edilmeli.',
              ),
            ),
          );
          return;
        case PurchaseFlowResult.unavailable:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Mağaza bağlantısı şu an kullanılamıyor.'),
            ),
          );
          return;
        case PurchaseFlowResult.timeout:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Satın alma doğrulaması zaman aşımına uğradı.'),
            ),
          );
          return;
        case PurchaseFlowResult.failed:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Satın alma tamamlanamadı.')),
          );
          return;
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yıllık plan aktivasyonu başarısız: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restorePurchase() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await PurchaseService.instance.restoreAnnualPlan();
      if (!mounted) return;

      if (result == PurchaseFlowResult.success ||
          result == PurchaseFlowResult.restored) {
        await MembershipState.instance.selectPlan(MembershipPlan.annual);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Yıllık plan geri yüklendi.')),
        );
        widget.onCompleted?.call();
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Aktif satın alım bulunamadı veya geri yüklenemedi.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Geri yükleme başarısız: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;
    final bgA = isDark ? const Color(0xFF050505) : const Color(0xFFF6F4EF);
    final bgB = isDark ? const Color(0xFF111111) : const Color(0xFFEAE4D7);
    final cardBg = isDark ? const Color(0xFF171717) : Colors.white;
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFD8D0BF);
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);
    final subtitleColor =
        isDark ? const Color(0xFFCEC7B7) : const Color(0xFF6B7280);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [bgA, bgB],
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              if (widget.allowClose)
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    onPressed: _busy
                        ? null
                        : () {
                            Navigator.of(context).maybePop();
                          },
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'Planını seç',
                style: TextStyle(
                  color: titleColor,
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Giriş yaptıktan sonra kullanacağın paketi seç. Free planda 5 şarkı ve 1 setlist hakkı var.',
                style: TextStyle(
                  color: subtitleColor,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 20),
              _PlanCard(
                title: 'Free Plan',
                price: '0 TL',
                accent: const Color(0xFFB89A59),
                cardBg: cardBg,
                border: border,
                titleColor: titleColor,
                subtitleColor: subtitleColor,
                features: const [
                  'En fazla 5 şarkı ekleme',
                  'En fazla 1 setlist oluşturma',
                  'Premium araçlar görünmez',
                ],
                actionLabel: _busy ? 'Bekleniyor...' : 'Free ile devam et',
                onPressed: _busy ? null : _selectFree,
              ),
              const SizedBox(height: 14),
              _PlanCard(
                title: 'Yıllık Plan',
                price: '100 TL / yıl',
                accent: const Color(0xFFFFC83D),
                cardBg: cardBg,
                border: border,
                titleColor: titleColor,
                subtitleColor: subtitleColor,
                features: const [
                  'Sınırsız şarkı ekleme',
                  'Sınırsız setlist',
                  'Akorlar, akort ve akort çıkarma erişimi',
                ],
                actionLabel:
                    _busy ? 'Satın alma bekleniyor...' : 'Yıllık plana geç',
                onPressed: _busy ? null : _buyAnnual,
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: _busy ? null : _restorePurchase,
                  child: const Text('Satın almayı geri yükle'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final String title;
  final String price;
  final Color accent;
  final Color cardBg;
  final Color border;
  final Color titleColor;
  final Color subtitleColor;
  final List<String> features;
  final String actionLabel;
  final VoidCallback? onPressed;

  const _PlanCard({
    required this.title,
    required this.price,
    required this.accent,
    required this.cardBg,
    required this.border,
    required this.titleColor,
    required this.subtitleColor,
    required this.features,
    required this.actionLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.14),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              title,
              style: TextStyle(
                color: titleColor,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            price,
            style: TextStyle(
              color: titleColor,
              fontSize: 28,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 14),
          for (final feature in features) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_circle_rounded, color: accent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    feature,
                    style: TextStyle(color: subtitleColor, height: 1.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: onPressed,
              child: Text(
                actionLabel,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
