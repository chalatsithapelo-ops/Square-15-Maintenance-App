import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:get/get.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'package:maintenanceapp/services/firestore_services/chat_service.dart';

class ChatScreen extends StatefulWidget {
  final TaskManagementModel task;
  final bool isArtisanSide;

  const ChatScreen({
    super.key,
    required this.task, this.isArtisanSide = false,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final AppController appController = Get.find();
  Future<void> addChatMessage(String message) async {
    if (message.trim().isEmpty) return;

    try {
      await ChatService.addChatMessage(
          taskId: widget.task.id.toString(),
          senderId: appController.userId.value,
          receiverId: widget.isArtisanSide
              ? widget.task.userId.toString()
              : widget.task.serviceProviderId.toString(),
          message: message);

      _messageController.clear();
    } catch (e) {
      debugPrint("❌ Error sending message: $e");
    }
  }

  @override
  void initState() {
    super.initState();
    ChatService.markMessagesAsRead(
        taskId: widget.task.id.toString(),
        currentUserId: appController.userId.value);

    // mark as active
    ChatService.setUserActiveStatus(
        taskId: widget.task.id.toString(),
        currentUserId: appController.userId.value);

  }

  @override
  void dispose() {
    ChatService.markMessagesAsRead(
        taskId: widget.task.id.toString(),
        currentUserId: appController.userId.value);
    ChatService.setUserActiveStatus(
        taskId: widget.task.id.toString(),
        currentUserId: appController.userId.value,
        status: false);
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(title: const Text("Chat")),
        body: Column(
          children: [
            // 🔹 Messages list
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection("tasksManagement")
                    .doc(widget.task.id)
                    .collection("chat")
                    .orderBy("timestamp", descending: false)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(child: Text("Error loading chat"));
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  var messages = snapshot.data!.docs;

                  return ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      var msg =
                      messages[index].data() as Map<String, dynamic>;
                      bool isMe =
                          msg["sender_id"] == appController.userId.value;

                      return Align(
                        alignment: isMe
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color:
                            isMe ? Color(0xFFe5c958) : Colors.grey[300],
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(msg["message"] ?? ""),
                        ),
                      );
                    },
                  );
                },
              ),
            ),

            // 🔹 Message input
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              color: Colors.grey[200],
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: const InputDecoration(
                        hintText: "Type a message...",
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send, color: Color(0xFFc5a520)),
                    onPressed: () => addChatMessage(_messageController.text),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
