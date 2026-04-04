import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:maintenanceapp/screens/home/profile/chat_support/widgets/chat_bubble.dart';
import 'package:maintenanceapp/screens/home/profile/chat_support/widgets/chatinputfield.dart';
import 'package:maintenanceapp/screens/home/profile/chat_support/widgets/header.dart';

import 'controller/help_center_controller.dart';


class ChatSupportScreen extends StatefulWidget {
  const ChatSupportScreen({super.key});

  @override
  State<ChatSupportScreen> createState() => _ChatSupportScreenState();
}

class _ChatSupportScreenState extends State<ChatSupportScreen> with SingleTickerProviderStateMixin {
  final HelpCenterController helpCenterController = Get.put(HelpCenterController());
  late final TextEditingController _messageController;
  final ScrollController _scrollController = ScrollController();
  late final TabController _tabController;

  static const _defaultFaqs = <Map<String, String>>[
    {'q': 'How do I book a service?', 'a': 'Go to the Home tab, select a category, choose your tasks, pick a date/time, and confirm your booking.'},
    {'q': 'How do I pay for a service?', 'a': 'You can pay via Wallet balance, PayFast (credit/debit card), or Buy Now Pay Later (PayJustNow, MoreTyme, Happy Pay, or Mobicred).'},
    {'q': 'How do I top up my wallet?', 'a': 'Go to Profile → Wallet and follow the top-up instructions. You can add funds via PayFast.'},
    {'q': 'Can I cancel a booking?', 'a': 'Yes, you can cancel a pending booking from the Bookings tab. Once an artisan has accepted, please contact support.'},
    {'q': 'What if the artisan doesn\'t show up?', 'a': 'Contact support via the chat tab. We will reassign your booking or process a refund.'},
    {'q': 'How do I request a quote (RFQ)?', 'a': 'Tap "Request a Quote" on the Home screen, describe your job, and an admin will send you a custom quote.'},
    {'q': 'How do I rate an artisan?', 'a': 'After the job is completed, you\'ll see a rating prompt on the booking detail screen.'},
  ];

  @override
  void initState() {
    super.initState();
    _messageController = TextEditingController();
    _tabController = TabController(length: 2, vsync: this);
  }


  @override
  void dispose() {
    _tabController.dispose();
    Get.delete<HelpCenterController>(force: true);
    super.dispose();
  }


  void _scrollToEnd() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  String formatTime(Timestamp? timestamp) {
    if (timestamp == null) return "Now";
    final date = timestamp.toDate();
    return "${date.hour}:${date.minute.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Container(
          padding: const EdgeInsets.only(left: 10,right: 10,top: 10),
          child: Column(
            children: [
              ChatSupportHeader(screenWidth: screenWidth, onBackPressed: (){
                Navigator.pop(context);
              }),
              TabBar(
                controller: _tabController,
                labelColor: const Color(0xFFD4A843),
                unselectedLabelColor: Colors.grey,
                indicatorColor: const Color(0xFFD4A843),
                tabs: const [
                  Tab(text: 'FAQ'),
                  Tab(text: 'Support Chat'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildFaqTab(),
                    _buildChatTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFaqTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('faq').orderBy('order').snapshots(),
      builder: (context, snapshot) {
        final firestoreFaqs = <Map<String, String>>[];
        if (snapshot.hasData) {
          for (final doc in snapshot.data!.docs) {
            final d = doc.data() as Map<String, dynamic>;
            firestoreFaqs.add({
              'q': (d['question'] ?? '').toString(),
              'a': (d['answer'] ?? '').toString(),
            });
          }
        }
        final allFaqs = firestoreFaqs.isNotEmpty ? firestoreFaqs : _defaultFaqs;
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: allFaqs.length,
          itemBuilder: (context, index) {
            final faq = allFaqs[index];
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                leading: Icon(Icons.help_outline, color: const Color(0xFFD4A843)),
                title: Text(faq['q'] ?? '', style: GoogleFonts.lato(fontWeight: FontWeight.w600, fontSize: 14)),
                children: [
                  Text(faq['a'] ?? '', style: GoogleFonts.lato(fontSize: 13, color: Colors.grey.shade700, height: 1.4)),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildChatTab() {
    return Column(
      children: [
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: helpCenterController.getMessages(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return Center(child: CircularProgressIndicator());
              }
              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return const Center(child: Text("No messages yet"));
              }

              helpCenterController.updateMessagesToRead();

              final messages = snapshot.data!.docs;
              WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
              return Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16.0),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      bool isUser = message['sender_type'] == 'USER';

                      return ChatSupportBubble(
                        message: message['message'],
                        time: formatTime(message['timestamp']),
                        isUser: isUser,
                      );
                    },
                  ),
                  Obx(()=> helpCenterController.isLoading.value
                      ? Positioned(
                        child: Center(child: CircularProgressIndicator()),
                      )
                      : const SizedBox()),

                ],
              );
            },
          ),
        ),
        StreamBuilder<QuerySnapshot>(
          stream: helpCenterController.getDeleteBtnStatus(),
          builder: (ctx, snapshot) {
            if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
              return ChatInputField(
                controller: _messageController,
                onSend: () {
                  final messageText = _messageController.text.trim();
                  if (messageText.isNotEmpty) {
                    helpCenterController.sendMessage(message: messageText);
                    _messageController.clear();
                  }
                },
              );
            }
            return Padding(padding: const EdgeInsets.all(16),
                child: Text('Ticket has been closed',
                    style: TextStyle(color: Colors.red.shade500)));
          },
        ),
      ],
    );
  }
}

// Chat bubble widget
