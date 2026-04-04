import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/model/corporate_partner_model.dart';
import 'package:maintenanceapp/services/corporate_partner_service.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

class PartnerReferralsScreen extends StatefulWidget {
  const PartnerReferralsScreen({super.key});

  @override
  State<PartnerReferralsScreen> createState() => _PartnerReferralsScreenState();
}

class _PartnerReferralsScreenState extends State<PartnerReferralsScreen> {
  final AppController _appController = Get.find();
  CorporatePartnerModel? _partner;
  Map<String, dynamic>? _stats;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPartnerData();
  }

  Future<void> _loadPartnerData() async {
    try {
      final partner = await CorporatePartnerService.getPartnerForUser(
        _appController.userId.value,
      );
      if (partner != null && partner.id != null) {
        final stats = await CorporatePartnerService.getPartnerStats(partner.id!);
        setState(() {
          _partner = partner;
          _stats = stats;
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      debugPrint('Error loading partner data: $e');
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return Scaffold(
      appBar: AppBar(
        title: Text('My Referrals',
            style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        backgroundColor: const Color(0xFFc5a520),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFc5a520)))
          : _partner == null
              ? _buildNotAPartner(width)
              : _buildPartnerDashboard(width),
    );
  }

  Widget _buildNotAPartner(double width) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.handshake_outlined,
                size: width * 0.2, color: Colors.grey.shade400),
            const SizedBox(height: 24),
            Text(
              'Become a Referral Partner',
              style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xff252525)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'Are you a property manager or corporate representative? '
              'Partner with Square 15 to earn commissions on every job '
              'booked by your referred tenants.',
              style: GoogleFonts.roboto(
                  fontSize: 14, color: Colors.grey.shade600, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _applyAsPartner,
                icon: const Icon(Icons.send),
                label: const Text('Apply as Referral Partner'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFc5a520),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  textStyle: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Or contact us: admin@square15.co.za',
              style: GoogleFonts.roboto(
                  fontSize: 13,
                  color: Colors.grey.shade500),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _applyAsPartner() async {
    final nameCtrl = TextEditingController();
    final companyCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();

    // Pre-fill from user profile
    final userData = _appController.userData;
    nameCtrl.text = userData?.name ?? '';
    emailCtrl.text = userData?.email ?? '';
    phoneCtrl.text = (userData?.contact ?? '').toString();

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Referral Partner Application',
            style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Full Name *',
                  prefixIcon: Icon(Icons.person),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: companyCtrl,
                decoration: const InputDecoration(
                  labelText: 'Company / Property Name *',
                  prefixIcon: Icon(Icons.business),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emailCtrl,
                decoration: const InputDecoration(
                  labelText: 'Email *',
                  prefixIcon: Icon(Icons.email),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneCtrl,
                decoration: const InputDecoration(
                  labelText: 'Phone Number',
                  prefixIcon: Icon(Icons.phone),
                ),
                keyboardType: TextInputType.phone,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty ||
                  companyCtrl.text.trim().isEmpty ||
                  emailCtrl.text.trim().isEmpty) {
                Get.snackbar('Missing fields',
                    'Please fill in name, company and email',
                    backgroundColor: Colors.red, colorText: Colors.white);
                return;
              }
              Navigator.pop(ctx, true);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFc5a520),
              foregroundColor: Colors.white,
            ),
            child: const Text('Submit'),
          ),
        ],
      ),
    );

    if (result != true) return;

    try {
      setState(() => _loading = true);
      await FirebaseFirestore.instance.collection('partner_applications').add({
        'user_id': _appController.userId.value,
        'name': nameCtrl.text.trim(),
        'company_name': companyCtrl.text.trim(),
        'email': emailCtrl.text.trim(),
        'phone': phoneCtrl.text.trim(),
        'status': 'pending',
        'created_at': FieldValue.serverTimestamp(),
      });

      // Notify admin
      await FirebaseFirestore.instance.collection('notifications').add({
        'title': 'New Partner Application',
        'body': '${nameCtrl.text.trim()} from ${companyCtrl.text.trim()} has applied to become a referral partner.',
        'type': 'partner_application',
        'user_type': 'admin',
        'read': false,
        'time': DateTime.now().toString(),
        'created_at': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        Get.snackbar('Application Submitted',
            'Your referral partner application has been submitted. We\'ll review it shortly.',
            backgroundColor: Colors.green, colorText: Colors.white,
            duration: const Duration(seconds: 4));
      }
    } catch (e) {
      debugPrint('Error submitting application: $e');
      if (mounted) {
        Get.snackbar('Error', 'Failed to submit application. Please try again.',
            backgroundColor: Colors.red, colorText: Colors.white);
      }
    } finally {
      setState(() => _loading = false);
    }
  }

  Widget _buildPartnerDashboard(double width) {
    final partner = _partner!;
    final stats = _stats ?? {};
    final fmt = NumberFormat.currency(symbol: 'R', decimalDigits: 2);
    final referralLink =
        'https://square15.co.za/ref?code=${partner.referralCode ?? ''}';

    return RefreshIndicator(
      color: const Color(0xFFc5a520),
      onRefresh: _loadPartnerData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- Header card ----
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFe5c958), Color(0xFFc5a520)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(partner.companyName ?? '',
                          style: GoogleFonts.inter(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.white)),
                    ),
                    _tierBadge(partner.commissionTier ?? 'bronze'),
                  ],
                ),
                const SizedBox(height: 4),
                Text(partner.contactName ?? '',
                    style: GoogleFonts.roboto(
                        fontSize: 14, color: Colors.white70)),
                const SizedBox(height: 16),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Commission Rate',
                          style: GoogleFonts.roboto(
                              fontSize: 13, color: Colors.white70)),
                      Text('${partner.commissionRate}%',
                          style: GoogleFonts.inter(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ---- Stats grid ----
          Row(
            children: [
              _statCard(
                  'Total Referrals',
                  '${stats['totalReferrals'] ?? partner.totalReferrals ?? 0}',
                  Icons.people,
                  width),
              const SizedBox(width: 12),
              _statCard(
                  'This Month',
                  '${stats['monthlyJobCount'] ?? 0} jobs',
                  Icons.calendar_today,
                  width),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _statCard(
                  'Total Earned',
                  fmt.format(stats['totalEarned'] ?? partner.totalEarned ?? 0),
                  Icons.account_balance_wallet,
                  width),
              const SizedBox(width: 12),
              _statCard(
                  'Pending Payout',
                  fmt.format(stats['pendingPayout'] ?? partner.pendingPayout ?? 0),
                  Icons.pending_actions,
                  width),
            ],
          ),
          const SizedBox(height: 24),

          // ---- Referral Code + QR ----
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                    color: Colors.grey.shade200,
                    blurRadius: 8,
                    offset: const Offset(0, 2))
              ],
            ),
            child: Column(
              children: [
                Text('Your Referral Code',
                    style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey.shade600)),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(
                        ClipboardData(text: partner.referralCode ?? ''));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Referral code copied!'),
                          duration: Duration(seconds: 2)),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F0E0),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: const Color(0xFFc5a520), width: 1.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(partner.referralCode ?? '',
                            style: GoogleFonts.robotoMono(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xff252525),
                                letterSpacing: 2)),
                        const SizedBox(width: 12),
                        const Icon(Icons.copy,
                            size: 20, color: Color(0xFFc5a520)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                QrImageView(
                  data: referralLink,
                  version: QrVersions.auto,
                  size: 180,
                  gapless: true,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Share.share(
                        'Sign up on Square 15 using my referral code: '
                            '${partner.referralCode ?? ''}\n\n$referralLink',
                      );
                    },
                    icon: const Icon(Icons.share),
                    label: const Text('Share Referral Link'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFc5a520),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ---- Commission Tiers ----
          Text('Commission Tiers',
              style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xff252525))),
          const SizedBox(height: 12),
          _tierRow('Bronze', '5%', '1 – 20 jobs/month',
              (partner.commissionTier ?? 'bronze') == 'bronze'),
          _tierRow('Silver', '7.5%', '21 – 50 jobs/month',
              (partner.commissionTier ?? 'bronze') == 'silver'),
          _tierRow('Gold', '10%', '51+ jobs/month',
              (partner.commissionTier ?? 'bronze') == 'gold'),
          const SizedBox(height: 24),

          // ---- Recent Commissions ----
          Text('Recent Commissions',
              style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xff252525))),
          const SizedBox(height: 12),
          StreamBuilder<QuerySnapshot>(
            stream: CorporatePartnerService.commissionsForPartner(partner.id ?? ''),
            builder: (ctx, snapshot) {
              if (!snapshot.hasData) {
                return const Center(
                    child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(color: Color(0xFFc5a520)),
                ));
              }
              final docs = snapshot.data!.docs;
              if (docs.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                      child: Text('No commissions yet',
                          style: GoogleFonts.roboto(color: Colors.grey))),
                );
              }
              return ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: docs.length > 20 ? 20 : docs.length,
                itemBuilder: (ctx, i) {
                  final data = docs[i].data() as Map<String, dynamic>;
                  final amount = (data['commission_amount'] ?? 0).toDouble();
                  final status = data['status'] ?? 'pending';
                  final createdAt = data['created_at'];
                  String dateStr = '';
                  if (createdAt is Timestamp) {
                    dateStr = DateFormat('dd MMM yyyy')
                        .format(createdAt.toDate());
                  }
                  return Card(
                    elevation: 0.5,
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: status == 'paid_out'
                            ? Colors.green.shade50
                            : Colors.orange.shade50,
                        child: Icon(
                          status == 'paid_out'
                              ? Icons.check_circle
                              : Icons.pending,
                          color: status == 'paid_out'
                              ? Colors.green
                              : Colors.orange,
                        ),
                      ),
                      title: Text(fmt.format(amount),
                          style: GoogleFonts.inter(
                              fontWeight: FontWeight.w600)),
                      subtitle: Text(
                          '${data['client_name'] ?? 'Client'} • $dateStr',
                          style: GoogleFonts.roboto(
                              fontSize: 12, color: Colors.grey)),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: status == 'paid_out'
                              ? Colors.green.shade50
                              : Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          status == 'paid_out' ? 'Paid' : 'Pending',
                          style: GoogleFonts.roboto(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: status == 'paid_out'
                                ? Colors.green
                                : Colors.orange,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _tierBadge(String tier) {
    final colors = {
      'bronze': [const Color(0xFFCD7F32), const Color(0xFFB8860B)],
      'silver': [const Color(0xFFC0C0C0), const Color(0xFFA8A8A8)],
      'gold': [const Color(0xFFFFD700), const Color(0xFFDAA520)],
    };
    final tierColors = colors[tier] ?? colors['bronze']!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: tierColors),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        tier.toUpperCase(),
        style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            letterSpacing: 1),
      ),
    );
  }

  Widget _statCard(String label, String value, IconData icon, double width) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
                color: Colors.grey.shade200,
                blurRadius: 6,
                offset: const Offset(0, 2))
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: const Color(0xFFc5a520), size: 22),
            const SizedBox(height: 8),
            Text(value,
                style: GoogleFonts.inter(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(label,
                style: GoogleFonts.roboto(
                    fontSize: 11, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }

  Widget _tierRow(String name, String rate, String range, bool isActive) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFFF5F0E0) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isActive ? const Color(0xFFc5a520) : Colors.grey.shade200,
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          if (isActive)
            const Icon(Icons.check_circle,
                color: Color(0xFFc5a520), size: 20)
          else
            Icon(Icons.circle_outlined,
                color: Colors.grey.shade300, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(name,
                style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight:
                        isActive ? FontWeight.bold : FontWeight.w500)),
          ),
          Text(rate,
              style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFFc5a520))),
          const SizedBox(width: 12),
          Text(range,
              style: GoogleFonts.roboto(
                  fontSize: 11, color: Colors.grey.shade500)),
        ],
      ),
    );
  }
}
