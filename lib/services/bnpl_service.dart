import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Supported Buy-Now-Pay-Later providers.
enum BnplProvider {
  payJustNow,
  moreTyme,
  happyPay,
  mobicred,
}

/// Multi-provider Buy-Now-Pay-Later integration.
///
/// Supported providers:
///   • PayJustNow — 3 interest-free payments over 6 weeks
///   • MoreTyme   — 3 interest-free payments over 2 months (by TymeBank)
///   • Happy Pay  — 4 interest-free monthly instalments
///   • Mobicred   — Revolving credit facility, 6–12 months
///
/// Each provider's configuration is stored in Firestore
/// `app_config/bnpl_<provider>` so the admin can toggle
/// sandbox/production, update API keys, and enable/disable per provider.
class BnplService {
  // ── Provider metadata ─────────────────────────────────

  static const Map<BnplProvider, BnplProviderInfo> providerInfo = {
    BnplProvider.payJustNow: BnplProviderInfo(
      id: 'payJustNow',
      name: 'PayJustNow',
      tagline: 'Pay in 3 interest-free instalments',
      instalments: 3,
      periodLabel: '6 weeks',
      intervalDays: 14,
      minAmount: 50.0,
      maxAmount: 50000.0,
      sandboxBase: 'https://sandbox.payjustnow.com/api/v2',
      productionBase: 'https://api.payjustnow.com/v2',
      configDoc: 'bnpl_payJustNow',
    ),
    BnplProvider.moreTyme: BnplProviderInfo(
      id: 'moreTyme',
      name: 'MoreTyme',
      tagline: 'Pay in 3 interest-free instalments',
      instalments: 3,
      periodLabel: '2 months',
      intervalDays: 30,
      minAmount: 100.0,
      maxAmount: 10000.0,
      sandboxBase: 'https://sandbox-api.moretyme.co.za/v2',
      productionBase: 'https://api.moretyme.co.za/v2',
      configDoc: 'bnpl_moreTyme',
    ),
    BnplProvider.happyPay: BnplProviderInfo(
      id: 'happyPay',
      name: 'Happy Pay',
      tagline: 'Pay in 4 interest-free monthly instalments',
      instalments: 4,
      periodLabel: '4 months',
      intervalDays: 30,
      minAmount: 100.0,
      maxAmount: 20000.0,
      sandboxBase: 'https://sandbox-api.happypay.co.za/v1',
      productionBase: 'https://api.happypay.co.za/v1',
      configDoc: 'bnpl_happyPay',
    ),
    BnplProvider.mobicred: BnplProviderInfo(
      id: 'mobicred',
      name: 'Mobicred',
      tagline: 'Revolving credit — up to 12 months',
      instalments: 6,
      periodLabel: '6 months',
      intervalDays: 30,
      minAmount: 150.0,
      maxAmount: 50000.0,
      sandboxBase: 'https://sandbox.mobicred.co.za/api/v3',
      productionBase: 'https://api.mobicred.co.za/v3',
      configDoc: 'bnpl_mobicred',
    ),
  };

  // ── Config ──────────────────────────────────────────────

  /// Loads configuration for a specific BNPL provider.
  /// Returns null if the provider is not configured / disabled.
  static Future<BnplConfig?> getConfig(BnplProvider provider) async {
    final info = providerInfo[provider]!;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('app_config')
          .doc(info.configDoc)
          .get();
      if (!snap.exists) return null;
      final data = snap.data() ?? {};
      if (data['enabled'] != true) return null;
      return BnplConfig.fromMap(data, provider);
    } catch (e) {
      debugPrint('[BnplService] getConfig(${info.name}) error: $e');
      return null;
    }
  }

  /// Returns all BNPL providers that are enabled AND eligible for [amount].
  static Future<List<BnplProvider>> getAvailableProviders(double amount) async {
    final available = <BnplProvider>[];
    for (final provider in BnplProvider.values) {
      if (!isEligible(provider, amount)) continue;
      final config = await getConfig(provider);
      if (config != null) available.add(provider);
    }
    return available;
  }

  // ── Eligibility ─────────────────────────────────────────

  /// Checks if an amount qualifies for a given provider.
  static bool isEligible(BnplProvider provider, double amount) {
    final info = providerInfo[provider]!;
    return amount >= info.minAmount && amount <= info.maxAmount;
  }

  /// Returns providers whose amount range covers [amount].
  static List<BnplProvider> eligibleProviders(double amount) {
    return BnplProvider.values
        .where((p) => isEligible(p, amount))
        .toList();
  }

  // ── Order Creation ──────────────────────────────────────

  /// Creates a BNPL order and returns the checkout redirect URL.
  static Future<BnplOrderResult?> createOrder({
    required BnplProvider provider,
    required double amount,
    required String orderId,
    required String consumerEmail,
    required String consumerFirstName,
    required String consumerLastName,
    required String consumerPhone,
    String? description,
  }) async {
    final config = await getConfig(provider);
    final info = providerInfo[provider]!;
    if (config == null) {
      debugPrint('[BnplService] ${info.name} not configured or disabled');
      return null;
    }

    final baseUrl = config.useSandbox ? info.sandboxBase : info.productionBase;
    final uri = Uri.parse('$baseUrl/order');

    final body = {
      'amount': amount.toStringAsFixed(2),
      'consumer': {
        'phoneNumber': consumerPhone,
        'givenNames': consumerFirstName,
        'surname': consumerLastName,
        'email': consumerEmail,
      },
      'merchant': {
        'redirectConfirmUrl': config.confirmUrl,
        'redirectCancelUrl': config.cancelUrl,
      },
      'merchantReference': orderId,
      'description': description ?? 'Square 15 Maintenance Payment',
      'taxAmount': '0.00',
      'shippingAmount': '0.00',
    };

    try {
      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${config.apiKey}',
        },
        body: jsonEncode(body),
      );

      debugPrint('[BnplService] ${info.name} createOrder status=${response.statusCode}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        final token = data['token']?.toString() ?? '';
        final redirectUrl = data['redirectCheckoutUrl']?.toString() ??
            data['redirect_url']?.toString() ??
            data['checkoutUrl']?.toString() ??
            '';

        if (token.isEmpty || redirectUrl.isEmpty) {
          debugPrint('[BnplService] ${info.name} missing token/redirectUrl');
          return null;
        }

        await _storeOrder(
          provider: provider,
          orderId: orderId,
          token: token,
          amount: amount,
          consumerEmail: consumerEmail,
          status: 'pending',
        );

        return BnplOrderResult(
          token: token,
          redirectUrl: redirectUrl,
          orderId: orderId,
          provider: provider,
        );
      } else {
        debugPrint('[BnplService] ${info.name} createOrder failed: ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('[BnplService] ${info.name} createOrder exception: $e');
      return null;
    }
  }

  // ── Order Status ────────────────────────────────────────

  /// Checks the status of a BNPL order by token.
  static Future<String> getOrderStatus(BnplProvider provider, String token) async {
    final config = await getConfig(provider);
    final info = providerInfo[provider]!;
    if (config == null) return 'ERROR';

    final baseUrl = config.useSandbox ? info.sandboxBase : info.productionBase;
    final uri = Uri.parse('$baseUrl/order/$token');

    try {
      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer ${config.apiKey}'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return (data['orderStatus'] ?? data['status'] ?? 'UNKNOWN')
            .toString()
            .toUpperCase();
      }
      return 'ERROR';
    } catch (e) {
      debugPrint('[BnplService] ${info.name} getOrderStatus error: $e');
      return 'ERROR';
    }
  }

  /// Captures (confirms) a BNPL order after approval.
  static Future<bool> captureOrder(BnplProvider provider, String token) async {
    final config = await getConfig(provider);
    final info = providerInfo[provider]!;
    if (config == null) return false;

    final baseUrl = config.useSandbox ? info.sandboxBase : info.productionBase;
    final uri = Uri.parse('$baseUrl/order/$token/capture');

    try {
      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer ${config.apiKey}',
          'Content-Type': 'application/json',
        },
      );

      debugPrint('[BnplService] ${info.name} captureOrder status=${response.statusCode}');
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (e) {
      debugPrint('[BnplService] ${info.name} captureOrder error: $e');
      return false;
    }
  }

  // ── Instalment Calculator ───────────────────────────────

  /// Returns the instalment breakdown for a given provider and amount.
  static List<BnplInstalment> calculateInstalments(
      BnplProvider provider, double totalAmount) {
    final info = providerInfo[provider]!;
    final perInstalment = totalAmount / info.instalments;
    final today = DateTime.now();
    return List.generate(info.instalments, (i) {
      final dueDate = today.add(Duration(days: i * info.intervalDays));
      return BnplInstalment(
        number: i + 1,
        amount: perInstalment,
        dueDate: dueDate,
        label: i == 0 ? 'Due today' : 'Due ${_formatDate(dueDate)}',
      );
    });
  }

  static String _formatDate(DateTime d) {
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month]}';
  }

  // ── Firestore Tracking ──────────────────────────────────

  static Future<void> _storeOrder({
    required BnplProvider provider,
    required String orderId,
    required String token,
    required double amount,
    required String consumerEmail,
    required String status,
  }) async {
    try {
      await FirebaseFirestore.instance
          .collection('bnpl_orders')
          .doc(orderId)
          .set({
        'order_id': orderId,
        'provider': providerInfo[provider]!.id,
        'provider_name': providerInfo[provider]!.name,
        'token': token,
        'amount': amount.toStringAsFixed(2),
        'consumer_email': consumerEmail,
        'status': status,
        'created_at': DateTime.now().toString(),
      });
    } catch (e) {
      debugPrint('[BnplService] _storeOrder error: $e');
    }
  }

  /// Updates order status in Firestore after checkout completes.
  static Future<void> updateOrderStatus({
    required String orderId,
    required String status,
    String? transactionId,
  }) async {
    try {
      final updates = <String, dynamic>{
        'status': status,
        'updated_at': DateTime.now().toString(),
      };
      if (transactionId != null) {
        updates['bnpl_transaction_id'] = transactionId;
      }
      await FirebaseFirestore.instance
          .collection('bnpl_orders')
          .doc(orderId)
          .update(updates);
    } catch (e) {
      debugPrint('[BnplService] updateOrderStatus error: $e');
    }
  }

  /// Gets BNPL order stats for admin dashboard (optionally filtered by provider).
  static Future<Map<String, dynamic>> getStats({BnplProvider? provider}) async {
    try {
      Query<Map<String, dynamic>> query =
          FirebaseFirestore.instance.collection('bnpl_orders');
      if (provider != null) {
        query = query.where('provider', isEqualTo: providerInfo[provider]!.id);
      }
      final snap = await query.get();

      int total = snap.docs.length;
      int approved = 0;
      int declined = 0;
      int pending = 0;
      double totalAmount = 0.0;
      double approvedAmount = 0.0;

      for (final doc in snap.docs) {
        final data = doc.data();
        final status = (data['status'] ?? '').toString().toLowerCase();
        final amount = double.tryParse(data['amount']?.toString() ?? '0') ?? 0;
        totalAmount += amount;

        if (status == 'approved' || status == 'captured') {
          approved++;
          approvedAmount += amount;
        } else if (status == 'declined' || status == 'cancelled') {
          declined++;
        } else {
          pending++;
        }
      }

      return {
        'total_orders': total,
        'approved': approved,
        'declined': declined,
        'pending': pending,
        'total_amount': totalAmount,
        'approved_amount': approvedAmount,
        'approval_rate':
            total > 0 ? ((approved / total) * 100).toStringAsFixed(1) : '0.0',
      };
    } catch (e) {
      debugPrint('[BnplService] getStats error: $e');
      return {};
    }
  }
}

// ── Data Classes ────────────────────────────────────────

class BnplProviderInfo {
  final String id;
  final String name;
  final String tagline;
  final int instalments;
  final String periodLabel;
  final int intervalDays;
  final double minAmount;
  final double maxAmount;
  final String sandboxBase;
  final String productionBase;
  final String configDoc;

  const BnplProviderInfo({
    required this.id,
    required this.name,
    required this.tagline,
    required this.instalments,
    required this.periodLabel,
    required this.intervalDays,
    required this.minAmount,
    required this.maxAmount,
    required this.sandboxBase,
    required this.productionBase,
    required this.configDoc,
  });
}

class BnplConfig {
  final String apiKey;
  final bool useSandbox;
  final String confirmUrl;
  final String cancelUrl;
  final bool enabled;
  final double merchantFeePercent;
  final BnplProvider provider;

  BnplConfig({
    required this.apiKey,
    required this.useSandbox,
    required this.confirmUrl,
    required this.cancelUrl,
    required this.enabled,
    required this.provider,
    this.merchantFeePercent = 5.0,
  });

  factory BnplConfig.fromMap(Map<String, dynamic> map, BnplProvider provider) {
    final info = BnplService.providerInfo[provider]!;
    return BnplConfig(
      apiKey: map['api_key']?.toString() ?? '',
      useSandbox: map['use_sandbox'] == true,
      confirmUrl: map['confirm_url']?.toString() ??
          'https://square15.co.za/bnpl/${info.id}/confirm',
      cancelUrl: map['cancel_url']?.toString() ??
          'https://square15.co.za/bnpl/${info.id}/cancel',
      enabled: map['enabled'] == true,
      provider: provider,
      merchantFeePercent:
          double.tryParse(map['merchant_fee_percent']?.toString() ?? '5.0') ??
              5.0,
    );
  }

  Map<String, dynamic> toMap() {
    final info = BnplService.providerInfo[provider]!;
    return {
      'api_key': apiKey,
      'use_sandbox': useSandbox,
      'confirm_url': confirmUrl,
      'cancel_url': cancelUrl,
      'enabled': enabled,
      'merchant_fee_percent': merchantFeePercent,
      'provider': info.id,
      'provider_name': info.name,
    };
  }
}

class BnplOrderResult {
  final String token;
  final String redirectUrl;
  final String orderId;
  final BnplProvider provider;

  BnplOrderResult({
    required this.token,
    required this.redirectUrl,
    required this.orderId,
    required this.provider,
  });
}

class BnplInstalment {
  final int number;
  final double amount;
  final DateTime dueDate;
  final String label;

  BnplInstalment({
    required this.number,
    required this.amount,
    required this.dueDate,
    required this.label,
  });
}
