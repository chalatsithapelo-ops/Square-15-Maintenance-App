import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maintenanceapp/model/user_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:maintenanceapp/screens/service_provider_panel/Serviceprovider/serviceproviderdashboard.dart';
import 'package:maintenanceapp/services/firestore_constants.dart';
import 'package:maintenanceapp/services/location_services.dart';
import 'package:maintenanceapp/utils/navigation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:maintenanceapp/utils/splash_timer.dart';
import '../screens/auth/login.dart';
import '../screens/auth/registerverify.dart';
import '../screens/home/bottomnavigationbar/bottombar.dart';

class AuthServices {

  static var userId = '';

  static Future<String?> _safeGetFcmToken() async {
    try {
      final token = await FirebaseMessaging.instance
          .getToken()
          .timeout(const Duration(seconds: 6));
      if (token == null || token.trim().isEmpty) return null;
      return token;
    } catch (_) {
      // Non-fatal: FCM can return SERVICE_NOT_AVAILABLE on some devices/networks.
      // Login/signup must still work.
      return null;
    }
  }

  static Future<void> _ensureUserProfileDoc({
    required String uid,
    required String email,
    String? fcmToken,
  }) async {
    final userRef = FirebaseFirestore.instance.collection("users").doc(uid);
    final existing = await userRef.get();

    if (!existing.exists) {
      Position? position;
      try {
        position = await AppLocationServices.getCurrentPosition();
      } catch (_) {
        position = null;
      }

      final userModel = UserModel(
        uid: uid,
        email: email,
        name: existing.data()?["name"],
        contact: existing.data()?["contact"],
        isAdmin: false,
        isServiceProvider: false,
        isUser: true,
        isVerified: false,
        lat: position != null ? position.latitude.toString() : '0.0',
        lng: position != null ? position.longitude.toString() : '0.0',
        deviceToken: fcmToken ?? '',
        image: existing.data()?["image"] ?? "",
        balance: existing.data()?["balance"] ?? "0",
      );

      final data = userModel.toMap();
      data['fcm_token'] = fcmToken ?? '';
      await userRef.set(data, SetOptions(merge: true));
      return;
    }

    if (fcmToken != null && fcmToken.trim().isNotEmpty) {
      await userRef.update({"deviceToken": fcmToken, "fcm_token": fcmToken});
    }
  }

  static customerSignUp({
    required BuildContext context,
    String? name,
    String? email,
    String? password,
    String? contact,
  }) async {
    try {
      EasyLoading.show(status: "Please wait");
      await FirebaseAuth.instance.createUserWithEmailAndPassword(email: email!, password: password!);
      final token = await _safeGetFcmToken();
      Position? position = await AppLocationServices.getCurrentPosition();
      UserModel userModel = UserModel(
          uid: FirebaseAuth.instance.currentUser!.uid,
          name: name,
          email: email,
          contact: int.tryParse(contact!),
          isAdmin: false,
          isServiceProvider: false,
          isUser: true,
          isVerified: false,
          lat: position != null ? position.latitude.toString() : '0.0',
          lng: position != null ? position.longitude.toString() : '0.0',
            deviceToken : token ?? '',
          image: "",
          balance: "0",
      );
      final data = userModel.toMap();
      // Keep both token fields in sync (legacy + booking flow).
      data['fcm_token'] = token ?? '';
      await FirebaseFirestore.instance
          .collection("users")
          .doc(FirebaseAuth.instance.currentUser!.uid)
          .set(data);
      EasyLoading.dismiss();
      navigateToPage(context: context, pageName: const Login());
    } on FirebaseAuthException catch (e) {
      EasyLoading.showError(e.message.toString());
      EasyLoading.dismiss();
    }
  }

  static signIn({
    required BuildContext context,
    String? email,
    String? password,
  }) async {
    EasyLoading.show(status: "Please wait");

    try {
      var id = "";
      final token = await _safeGetFcmToken();

      final QuerySnapshot providerSnap = await FirebaseFirestore.instance
          .collection("serviceProvider")
          .where("email", isEqualTo: email)
          .where("password", isEqualTo: password!)
          .get();

      if (providerSnap.docs.isNotEmpty) {
        for (var e in providerSnap.docs) {
          id = e.id;
          userId = id;
          appController.userId.value = userId;
        }

        if (token != null) {
          await FirebaseFirestore.instance
              .collection("serviceProvider")
              .doc(id)
              .update({"deviceToken": token, "fcm_token": token});
        }

        EasyLoading.dismiss();
        appController.saveLoginCredentials(
            type: "provider",
            id: userId,
            email: email!,
            password: password,
            isLogin: true);
        Navigator.pushAndRemoveUntil(context,
            MaterialPageRoute(builder: (BuildContext context) {
          return ServiceProviderDashboard(email: email, password: password);
        }), (route) => false);
        return;
      }

      final userCredential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email!, password: password);

      final uid = userCredential.user?.uid;
      if (uid == null || uid.trim().isEmpty) {
        EasyLoading.dismiss();
        EasyLoading.showError("Login failed: missing user id");
        return;
      }

      userId = uid;
      appController.userId.value = userId;
      await _ensureUserProfileDoc(uid: uid, email: email, fcmToken: token);

      await appController.getUser(id: uid);
      appController.saveLoginCredentials(
          type: "user",
          id: userId,
          email: email,
          password: password,
          isLogin: true);

      EasyLoading.dismiss();
      Navigator.pushAndRemoveUntil(context,
          MaterialPageRoute(builder: (BuildContext context) {
        return const BottomNavigatorExample();
      }), (route) => false);
    } on FirebaseAuthException catch (e) {
      EasyLoading.dismiss();
      if (e.code == 'user-not-found') {
        EasyLoading.showError(
            "No account found for this email (in the current Firebase project)");
      } else if (e.code == 'wrong-password') {
        // 'wrong-password' is also returned when the account exists but was
        // created via Google/Facebook (no password provider).  Detect that
        // case and give the user a clear message.
        try {
          final methods = await FirebaseAuth.instance
              .fetchSignInMethodsForEmail(email!);
          if (methods.contains('google.com') &&
              !methods.contains('password')) {
            EasyLoading.showError(
              'This account was created with Google sign-in. '
              'Please use the Google button to log in.',
            );
          } else {
            EasyLoading.showError("Incorrect password");
          }
        } catch (_) {
          EasyLoading.showError("Incorrect password");
        }
      } else if (e.code == 'invalid-credential') {
        // Firebase may return 'invalid-credential' on newer SDK versions
        // instead of 'wrong-password' for social-only accounts.
        try {
          final methods = await FirebaseAuth.instance
              .fetchSignInMethodsForEmail(email!);
          if (methods.contains('google.com') &&
              !methods.contains('password')) {
            EasyLoading.showError(
              'This account was created with Google sign-in. '
              'Please use the Google button to log in.',
            );
          } else if (methods.contains('facebook.com') &&
              !methods.contains('password')) {
            EasyLoading.showError(
              'This account was created with Facebook sign-in. '
              'Please use the Facebook button to log in.',
            );
          } else {
            EasyLoading.showError(e.message.toString());
          }
        } catch (_) {
          EasyLoading.showError(e.message.toString());
        }
      } else {
        EasyLoading.showError(e.message.toString());
      }
    } catch (e) {
      EasyLoading.dismiss();
      EasyLoading.showError(e.toString());
    }

  }

  static signInWithGoogle(BuildContext context) async {
    try {
      EasyLoading.show(status: 'Please wait');
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) {
        EasyLoading.dismiss();
        return;
      }
      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final userCredential = await FirebaseAuth.instance.signInWithCredential(credential);

      final token = await _safeGetFcmToken();
      final uid = userCredential.user!.uid;
      final email = userCredential.user!.email ?? '';

      // ── CRITICAL FIX: Use _ensureUserProfileDoc to preserve existing
      // balance. Previously this method created a UserModel with balance:"0"
      // and wrote it with set(merge:true), which OVERWROTE the user's
      // wallet balance to zero on every Google sign-in. ──
      await _ensureUserProfileDoc(
        uid: uid,
        email: email,
        fcmToken: token,
      );

      // If the doc was just created by _ensureUserProfileDoc, also set
      // the Google-specific display name if not already in Firestore.
      final userDoc = await FirebaseFirestore.instance
          .collection(FirestoreConstants.userCollection)
          .doc(uid)
          .get();
      if (userDoc.exists) {
        final existingName = (userDoc.data()?['name'] ?? '').toString().trim();
        if (existingName.isEmpty && userCredential.user!.displayName != null) {
          await FirebaseFirestore.instance
              .collection(FirestoreConstants.userCollection)
              .doc(uid)
              .update({'name': userCredential.user!.displayName});
        }
      }

      userId = uid;
      appController.userId.value = userId;

      await appController.getUser(id: userId);
      appController.saveLoginCredentials(
        type: "user",
        id: userId,
        email: email,
        password: '',
        isLogin: true,
      );

      EasyLoading.dismiss();
      Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => BottomNavigatorExample()),
          (route) => false);
    } on FirebaseAuthException catch (e) {
      EasyLoading.showError(e.message.toString());
      EasyLoading.dismiss();
    } catch (e) {
      // Google sign-in on Android commonly fails when SHA-1 isn't added to
      // the Firebase Android app settings for the signing certificate.
      EasyLoading.dismiss();
      EasyLoading.showError('Google sign-in failed. If this is a new Firebase project, add your app SHA-1 in Firebase → Project settings → Your apps → Android.');
    }
  }

  static Future<void> signInWithFacebook(BuildContext context) async {
    try {
      EasyLoading.show(status: 'Please wait');

      final loginResult = await FacebookAuth.instance.login(permissions: const ['email', 'public_profile']);
      if (loginResult.status != LoginStatus.success) {
        EasyLoading.dismiss();
        EasyLoading.showError('Facebook sign-in cancelled');
        return;
      }

      final accessToken = loginResult.accessToken;
      if (accessToken == null || accessToken.tokenString.trim().isEmpty) {
        EasyLoading.dismiss();
        EasyLoading.showError('Facebook sign-in failed');
        return;
      }

      final authCredential = FacebookAuthProvider.credential(accessToken.tokenString);
      final userCredential = await FirebaseAuth.instance.signInWithCredential(authCredential);

      final token = await _safeGetFcmToken();
      final uid = userCredential.user?.uid;
      final email = userCredential.user?.email;

      if (uid == null || uid.trim().isEmpty) {
        EasyLoading.dismiss();
        EasyLoading.showError('Facebook sign-in failed');
        return;
      }

      userId = uid;
      appController.userId.value = userId;

      await _ensureUserProfileDoc(
        uid: uid,
        email: (email ?? '').trim().isEmpty ? 'facebook_user' : email!,
        fcmToken: token,
      );

      await appController.getUser(id: uid);
      appController.saveLoginCredentials(
        type: 'user',
        id: uid,
        email: email ?? '',
        password: '',
        isLogin: true,
      );

      EasyLoading.dismiss();
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const BottomNavigatorExample()),
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      EasyLoading.dismiss();
      EasyLoading.showError(e.message.toString());
    } catch (e) {
      EasyLoading.dismiss();
      EasyLoading.showError(e.toString());
    }
  }

  static verifyPhoneNumber(String phoneNumber, BuildContext context) async {
    try {
      EasyLoading.show(status: "Please wait");
      await FirebaseAuth.instance.verifyPhoneNumber(
          phoneNumber: phoneNumber,
          verificationCompleted: (PhoneAuthCredential credential) {},
          verificationFailed: (e) {
            EasyLoading.showError(e.code.toString());
            EasyLoading.dismiss();
          },
          codeSent: (String verificationId, int? token) {
            EasyLoading.dismiss();
            navigateToPage(
                context: context,
                pageName: registerverify(
                  verificationId: verificationId,
                  phone: phoneNumber,
                ));
          },
          codeAutoRetrievalTimeout: (String verificationId) {});
    } on FirebaseAuthException catch (e) {
      EasyLoading.showError(e.code);
      EasyLoading.dismiss();
    }
  }
}
