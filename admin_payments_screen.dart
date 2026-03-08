import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'order_section_widget.dart';
import 'wallet_topups_screen.dart';
import 'transactions_monitor_screen.dart';

class PaymentsScreen extends StatelessWidget {
  const PaymentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
        padding: const EdgeInsets.all(15.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(
                child: Text('Payments',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 12),

              Card(
                elevation: 2,
                child: ListTile(
                  leading: const Icon(Icons.account_balance_wallet_outlined),
                  title: const Text('Wallet Top-ups'),
                  subtitle: const Text('Approve/reject proof-of-payment requests'),
                  trailing: StreamBuilder<int>(
                    stream: FirebaseFirestore.instance
                        .collection('requests')
                        .where('status', isEqualTo: 'pending')
                        .snapshots()
                        .map((s) => s.docs.length),
                    builder: (context, snapshot) {
                      final count = snapshot.data ?? 0;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (count > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                count > 99 ? '99+' : count.toString(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          const SizedBox(width: 10),
                          const Icon(Icons.chevron_right),
                        ],
                      );
                    },
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const WalletTopupsScreen()),
                    );
                  },
                ),
              ),
              const SizedBox(height: 20),

              Card(
                elevation: 2,
                child: ListTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('Transactions'),
                  subtitle: const Text('Live money-in / money-out monitor'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const TransactionsMonitorScreen()),
                    );
                  },
                ),
              ),
              const SizedBox(height: 20),

              OrdersSectionWidget(
                headingText: "Orders in Pending",
                queryField: 'accept',
                queryValue: '',
                viewColor: Colors.amber.shade100,
                viewBorderColor: Colors.amber.shade900,
              ),
              const SizedBox(height: 20),
              OrdersSectionWidget(
                headingText: "Orders in Progress",
                queryField: 'status',
                queryValue: const ['progress', 'in_progress', 'accepted', 'pending_assignment', 'confirmed', 'pending_payment'],
                useWhereIn: true,
                viewColor: Colors.cyan.shade100,
                viewBorderColor: Colors.cyan.shade900,
              ),
              const SizedBox(height: 20),
              OrdersSectionWidget(
                headingText: "Completed Orders",
                queryField: 'status',
                queryValue: 'completed',
                viewColor: Colors.green.shade100,
                viewBorderColor: Colors.green.shade900,
                headingColor: Colors.green.shade900,
              ),
              const SizedBox(height: 20),
              OrdersSectionWidget(
                headingText: "Closed Orders",
                queryField: 'status',
                queryValue: 'closed',
                viewColor: Colors.grey.shade100,
                viewBorderColor: Colors.grey,
                headingColor: Colors.grey.shade900,
              ),
              const SizedBox(height: 50),

            ],
          ),
        ),
    );
  }
}

