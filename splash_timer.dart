import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/screens/auth/login.dart';
import 'package:maintenanceapp/utils/navigation.dart';
import '../screens/home/bottomnavigationbar/bottombar.dart';
import '../screens/service_provider_panel/Serviceprovider/serviceproviderdashboard.dart';

// Lazy accessor — safely defers Get.find() until after Get.put() has run
// in splash _bootstrap(). The old top-level `Get.find()` ran at import
// time (before registration), crashing on fresh installs / updates.
AppController get appController {
  if (!Get.isRegistered<AppController>()) {
    Get.put(AppController());
  }
  return Get.find<AppController>();
}

splashTimer(BuildContext context) {
  final user = FirebaseAuth.instance.currentUser;
  debugPrint("Current User $user");
  debugPrint("Current User ${appController.isLogin.value}");
  Future.delayed(const Duration(seconds: 3),(){
    if(appController.isLogin.value == true && user != null){
      if(appController.userType.value == "user"){
        navigateToPage(context: context, pageName: const BottomNavigatorExample());
      }
      else{
        navigateToPage(context: context, pageName: ServiceProviderDashboard(
          email: appController.userEmail.value,
          password: appController.userPassword.value,));
      }

    }
    else {
      // debugPrint("user id ${user.uid}");
      // AuthServices.userId = user!.uid;
      navigateToPage(context: context, pageName: const Login());
    }
  });
}