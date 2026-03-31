import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:maintenanceapp/model/bot_response_model.dart';
import 'package:maintenanceapp/utils/helper.dart';

class BotController extends GetxController{


  var isSpeaking = false.obs;
  var isListening = false.obs;

  var yourQuestion = "".obs;
  var responseText = "".obs;
  late BotResponseModel responseModel;
  var choices = <Choice>[].obs;

  @override
  void onInit() {
    // TODO: implement onInit
    super.onInit();
  }


  Future<void> getResponse() async{

    responseText.value = 'Generating...!';
    try{
      final response = await http.post(
        Uri.parse('https://api.openai.com/v1/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${Helper.gptKey}'
        },
        body: jsonEncode({
            "model": "gpt-3.5-turbo-instruct",
            "prompt": yourQuestion.value,
            "max_tokens": 1000,
            "temperature": 0,
            "top_p": 1,
          }),
      );

      if(response.statusCode == 200){
        choices.value = botResponseModelFromJson(response.body).choices ?? [];
        responseText.value = choices[0].text!;
        // var data = jsonDecode(response.body);
        // debugPrint(data["usage"]["prompt_tokens"].toString());
        // debugPrint(data["usage"]["completion_tokens"].toString());
        // debugPrint(data["usage"]["total_tokens"].toString());

      }
      else{
        var data = jsonDecode(response.body);
        debugPrint(data["error"]["message"]);
        responseText.value = data["error"]["message"];
      }
    }catch(e){
      debugPrint("getResponse $e");
    }

  }

  Future<void> getResponseWithGroq() async {
    responseText.value = 'Generating...!';
    try {
      final question = yourQuestion.value.trim();
      if (question.isEmpty) {
        responseText.value = 'Please ask a question.';
        return;
      }

      final response = await http.post(
        Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${Helper.groqApiKey}', // 🔹 Store your key safely in Helper.groqApiKey
        },
        body: jsonEncode({
          "model": "llama-3.3-70b-versatile",
          "messages": [
            {
              "role": "system",
              "content": "You are Lizzy, the AI assistant for Square 15 Facility Solutions, a property maintenance company in South Africa. "
                  "You help clients with information about plumbing, electrical, painting, carpentry, roofing, tiling, locksmith, and other maintenance services. "
                  "Be helpful, friendly, and concise. Amounts are in South African Rand (R). "
                  "For booking or account actions, suggest the user use the full AI Chat or the app's booking flow."
            },
            {
              "role": "user",
              "content": question,
            }
          ],
          "max_tokens": 1000,
          "temperature": 0.7
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        // 🔹 Extract the message content from Groq’s response
        final answer = data['choices'][0]['message']['content']?.trim() ?? '';

        if (answer.isNotEmpty) {
          responseText.value = answer;
        } else {
          responseText.value = "Sorry, I didn’t understand that.";
        }

        debugPrint("✅ Groq replied: ${responseText.value}");
        debugPrint("✅ Groq replied: ${data.toString()}");
      } else {
        final error = jsonDecode(response.body);
        responseText.value =
        "Error ${response.statusCode}: ${error['error']?['message'] ?? 'Unknown error'}";
        debugPrint("⚠️ Groq error: ${response.body}");
      }
    } catch (e) {
      debugPrint("❌ getResponse error: $e");
      responseText.value = "Something went wrong. Please try again.";
    }
  }






}