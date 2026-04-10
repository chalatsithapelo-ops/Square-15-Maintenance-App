import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lottie/lottie.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/screens/home/bottomnavigationbar/bottombar.dart';
import 'package:maintenanceapp/screens/home/payment_detail.dart';
import 'package:maintenanceapp/services/firestore_services/firebase_services.dart';
import 'package:maintenanceapp/utils/dotted_line.dart';

class WaitingScreen extends StatefulWidget {
  final String cost;
  final String provideId;
  const WaitingScreen({super.key, required this.cost, required this.provideId});

  @override
  State<WaitingScreen> createState() => _WaitingScreenState();
}

class _WaitingScreenState extends State<WaitingScreen> {

  final AppController appController = Get.find();
  var casingVariations = [];
  late DateTime createdAt;
  Timer? timer;
  var taskName = "";
  var newProvider = "";
  Duration remainingTime = const Duration(seconds: 30);
  bool _alreadyNavigated = false;


  @override
  void initState()  {
    super.initState();
    int randomNumber = Random().nextInt(appController.selectedTaskNameList.length);
    taskName = appController.selectedTaskNameList[randomNumber];
    casingVariations = [
      taskName,
      taskName.toLowerCase(),
      taskName.toUpperCase()
    ];
    getTaskData();


  }

  Future<void> getTaskData() async{
    await appController.tasksManagementRef
        .doc(appController.newTaskIdForOrder.value).update({
          "creation_date" : DateTime.now().toString(),
          "status" : "",
          "service_provider_id": newProvider == "" ? widget.provideId : newProvider});
    appController.tasksManagementRef
        .doc(appController.newTaskIdForOrder.value)
        .get()
        .then((documentSnapshot) {
      if (documentSnapshot.exists) {
        String createdAtString = documentSnapshot['creation_date'];
        createdAt = DateTime.parse(createdAtString);
        startTimerOne();
      }
    });
  }
  void startTimerOne() {
    appController.remainingTimeString.value = "30";
    appController.timeUp.value = false;
    appController.sendNotification(to: newProvider == "" ? widget.provideId : newProvider, from: appController.userId.value);
    timer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
        final now = DateTime.now().subtract(const Duration(seconds: 1));
        final difference = now.difference(createdAt);
        remainingTime = const Duration(seconds: 30) - difference;
        appController.remainingTimeString.value = remainingTime.inSeconds.toString().padLeft(2, '0');
        if (remainingTime.inSeconds <= 0) {
          appController.timeUp.value = true;
          appController.timeUpOrderClose(id: appController.newTaskIdForOrder.value);
          t.cancel();
          timer = Timer.periodic(const Duration(seconds: 5), (Timer t) async {
            await findAndSendRequestToNewArtisan();
            timer?.cancel();
          });
        }
    });
  }


  Future<void> findAndSendRequestToNewArtisan() async {
    try{
      QuerySnapshot taskSnapshot = await appController.taskRef.get();
      var filterList = [];
      if(taskSnapshot.docs.isNotEmpty){
        debugPrint("New length ${taskSnapshot.docs.length}");
        ///get all task from firebase and filter where task name contains selected Task Name i.e Wall
        for (var element in taskSnapshot.docs) {
          if(element["name"].toString().toLowerCase().contains(taskName.toLowerCase())){
            filterList.add(element);
          }
        }

        // Now, if filter list is not empty and then pick Random from filtered list.
        if(filterList.isNotEmpty){
          debugPrint("Find Length ${filterList.length}");
          Random random = Random();
          int randomIndex = random.nextInt(filterList.length);
          var singleTask = filterList[randomIndex];
          debugPrint("Single Task ${singleTask.data()}");
          var artisanID = "";

          int randomTaskId = Random().nextInt(appController.selectedTaskIdList.length);
          debugPrint("random selected task id ${appController.selectedTaskIdList[randomTaskId]}");
          QuerySnapshot<Map<String, dynamic>> query = await FirebaseService.artisanTasks
              .where('status', isEqualTo: 'publish')
              .where('task_id', isEqualTo: appController.selectedTaskIdList[randomTaskId])
              .get();
          if(query.docs.isNotEmpty){
            artisanID = query.docs.first["user_id"];
            debugPrint("Single New User $artisanID");
            newProvider = artisanID.toString();
            EasyLoading.show(status: 'Sending Request...!');
            await getTaskData();
            EasyLoading.dismiss();
          }
          else{
            debugPrint("No Any other artisan");
          }

        }
      }
      appController.timeUp.value = false;
    }catch(e){
      if(EasyLoading.isShow){
        EasyLoading.dismiss();
      }
      debugPrint("findAndSendRequestToNewArtisan $e");
    }
  }



  @override
  void dispose() {
    timer?.cancel();
    if(EasyLoading.isShow){
      EasyLoading.dismiss();
    }
    super.dispose();
  }

  

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    return StreamBuilder<DocumentSnapshot>(
        stream: appController.tasksManagementRef.doc(appController.newTaskIdForOrder.value).snapshots(),
        builder: (context, snapshot){
          if (snapshot.connectionState == ConnectionState.active) {
            final status = snapshot.data?["accept"];
            appController.shouldNavigate.value = (status == '1' || status == '0');
            Future.microtask(() {
              if (appController.shouldNavigate.value && !_alreadyNavigated) {
                _alreadyNavigated = true;
                appController.isOrderApproveOrReject.value = true;
                _showSnackbarAndNavigate(status == '1');
              }
            });
            
            return  Scaffold(
              appBar: AppBar(
                backgroundColor: const Color(0xFFc5a520),
                title: const Text('Waiting for Artisan'),
              ),
              body: SingleChildScrollView(
                child: Container(
                  width: width,
                  height: height,
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [

                      Text('Task Info: ',style: GoogleFonts.inter(color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize:  width*0.05)),
                      SizedBox(height:  height*0.007),
                      CustomPaint(
                        size: Size( width,  height*0.01),
                        painter: DottedLinePainter(Colors.amber.shade400),
                      ),
                      SizedBox(height:  height*0.007),
                      card(title: 'Task Name', value: taskName, width:  width),
                      SizedBox(height:  height*0.01),
                      card(title: 'Task Cost', value: widget.cost, width:  width),
                      SizedBox(height:  height*0.01),

                      // Row(
                      //   mainAxisAlignment: MainAxisAlignment.center,
                      //   children: [
                      //     Obx(()=> Text("Remaining Seconds ${appController.remainingTimeString.value}",
                      //         style: GoogleFonts.lato(color: Colors.black, fontSize: 16))),
                      //   ],
                      // ),

                      Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          Obx(()=> appController.timeUp.value
                              ? Lottie.asset('assets/animations/failed.json' , height: height * 0.35)
                              : Lottie.asset('assets/animations/searching_1.json', height: height * 0.35)),
                          Positioned(
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Obx(()=> appController.timeUp.value
                                      ?const SizedBox()
                                      : const Text('Waiting for response')),

                                ],
                              )),
                        ],
                      ),
                      Align(
                        alignment: Alignment.center,
                        child: Column(
                          children: [
                            Obx(()=> appController.timeUp.value
                                ? Text('Please Wait! Finding More Artisans',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.lato(color: Colors.black, fontSize: 12))
                                : const SizedBox()),

                            ///Re-Send Button to Same Artisan
                            // Obx(()=> appController.timeUp.value
                            //     ? GestureDetector(
                            //       onTap: () async {
                            //         EasyLoading.show(status: 'Sending Request Again...!');
                            //         await getTaskData();
                            //         EasyLoading.dismiss();
                            //       },
                            //       child: Container(
                            //         margin: const EdgeInsets.only(top: 5),
                            //         padding: const EdgeInsets.all(6),
                            //         decoration: BoxDecoration(
                            //             color: const Color(0xFFc5a520),
                            //             borderRadius: BorderRadius.circular(50),
                            //             boxShadow: [
                            //               BoxShadow(
                            //                   color: const Color(0xFFc5a520).withOpacity(0.2),
                            //                   blurRadius: 0.5,spreadRadius: 0.5,
                            //                   offset: const Offset(1, 1)
                            //               )
                            //             ]
                            //         ),
                            //         child: const Icon(Icons.restart_alt, color: Colors.white,size: 26),
                            //       ),
                            //     )
                            //     : const SizedBox()),
                            SizedBox(height:  height*0.01),
                          ],
                        ),
                      ),
                      Obx(()=> appController.timeUp.value
                          ? const Divider() : const SizedBox()),

                        ///Other Artisans when TimeUp

                        // Obx(()=> appController.timeUp.value
                        //     ? SizedBox(
                        //       height:  height*0.2,
                        //       child: StreamBuilder(
                        //           stream: appController.taskRef
                        //               .where('name', whereIn: casingVariations).snapshots(),
                        //           builder: (context, snapshot){
                        //             // debugPrint("Length of Tasks ${snapshot.data!.docs.length}");
                        //             if(!snapshot.hasData){
                        //               return noText(text: 'No Artisan Available for ${widget.taskName}');
                        //             }
                        //             else {
                        //               return snapshot.data!.docs.isEmpty
                        //                   ? Center(child: noText(text: 'No Artisan Available for ${widget.taskName}'))
                        //                   : ListView.builder(
                        //                     physics: const BouncingScrollPhysics(),
                        //                     scrollDirection: Axis.horizontal,
                        //                     shrinkWrap: true,
                        //                     itemCount: snapshot.data!.docs.length,
                        //                     itemBuilder: (context, index){
                        //                       final data = snapshot.data!.docs[index];
                        //                       var artisanID = appController.artisanTasksList.where((p) => p.taskId == data["id"]).toList().first.userId;
                        //                       return Container(
                        //                         width: width*0.35,
                        //                         margin: const EdgeInsets.only(top: 5, right: 5),
                        //                         padding: const EdgeInsets.all(8),
                        //                         decoration: BoxDecoration(
                        //                             color: Colors.white,
                        //                             borderRadius: BorderRadius.circular(5),
                        //                             boxShadow: [
                        //                               BoxShadow(
                        //                                   color: const Color(0xFFc5a520).withOpacity(0.2),
                        //                                   blurRadius: 0.5,spreadRadius: 0.5,
                        //                                   offset: const Offset(1, 1)
                        //                               )
                        //                             ]
                        //                         ),
                        //                         child: StreamBuilder(
                        //                             stream: appController.serviceProviderRef.doc(artisanID).snapshots(),
                        //                             builder: (context, providerSnap){
                        //                               if(!providerSnap.hasData){
                        //                                 return noText(text: 'N/A');
                        //                               }
                        //                               else {
                        //                                 return Column(
                        //                                   mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        //                                   children: [
                        //                                     Row(
                        //                                       mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        //                                       children: [
                        //                                         ClipRRect(
                        //                                           borderRadius: BorderRadius.circular(5),
                        //                                           child: SizedBox(
                        //                                             child: providerSnap.data!["image"] == ""
                        //                                                 ? Container(
                        //                                                   width: width*0.35 / 3 , height: width*0.35 / 3,
                        //                                                   decoration: BoxDecoration(
                        //                                                       color: Colors.green.shade100,
                        //                                                       borderRadius: BorderRadius.circular(5),
                        //                                                       border: Border.all(color: Colors.green.shade100)
                        //                                                   ),
                        //                                                   child: Icon(Icons.no_accounts, color: Colors.green.shade900),
                        //                                                 )
                        //                                                 : Image.network(
                        //                                                   providerSnap.data!["image"],
                        //                                                   width: width*0.35 / 3 , height: width*0.35 / 3,
                        //                                                   fit: BoxFit.cover,
                        //                                                 ),
                        //                                           ),
                        //                                         ),
                        //                                         SizedBox(
                        //                                             width: width*0.35 / 2,
                        //                                             child: Text(providerSnap.data!["name"] ?? "", textAlign: TextAlign.start))
                        //                                       ],
                        //                                     ),
                        //                                     const SizedBox(height: 5),
                        //                                     Text('Service: ${data["name"]}'),
                        //                                     // const Spacer(),
                        //                                     Container(
                        //                                       margin: const EdgeInsets.only(top: 5),
                        //                                       // width: width*0.2,
                        //                                       height: width * 0.07,
                        //                                       child: PrimaryButton(
                        //                                         radius: 5,
                        //                                         fontSize: 14,
                        //                                         onPressed: () async {
                        //                                           newProvider = providerSnap.data!["docId"];
                        //                                           EasyLoading.show(status: 'Sending Request Again...!');
                        //                                           await getTaskData();
                        //                                           EasyLoading.dismiss();
                        //                                         },
                        //                                         title: "Send Request",
                        //                                       ),
                        //                                     ),
                        //                                   ],
                        //                                 );
                        //                               }
                        //                             }),
                        //                       );
                        //                     });
                        //             }
                        //           }))
                        //     : const SizedBox())

                    ],
                  ),
                ),
              ),
            );
          }
          else{
             return const Center(child: CircularProgressIndicator());
           }
        });
  }

  void _showSnackbarAndNavigate(bool isAccepted) {
    if (isAccepted) {
      appController.currentIndex.value = 2;
      Get.showSnackbar(
        const GetSnackBar(
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
          snackPosition: SnackPosition.TOP,
          title: 'Success',
          message: 'Request Accepted',
        ),
      );
    }
    else {
      appController.currentIndex.value = 0;
      Get.showSnackbar(
        const GetSnackBar(
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
          snackPosition: SnackPosition.TOP,
          title: 'Failure',
          message: 'Request Rejected',
        ),
      );
    }

    Get.offAll(() => const BottomNavigatorExample());
  }

}


