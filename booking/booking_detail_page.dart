import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:maintenanceapp/screens/home/booking/attachment_view.dart';
import 'package:maintenanceapp/screens/service_provider_panel/service_provider_request_screen.dart';
import 'package:maintenanceapp/services/firestore_services/firebase_services.dart';
import 'package:maintenanceapp/utils/common_widget.dart';

class BookingDetailPage extends StatelessWidget {
  final QueryDocumentSnapshot<Object?> data;
  final String taskName;
  final String requestId;
  final String pageName;
  const BookingDetailPage({super.key, required this.data, required this.taskName, required this.requestId, required this.pageName});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return SafeArea(
      child: Scaffold(
        body: SizedBox(
          height: height,
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Container(
                  width: double.infinity,
                  height: height * 0.15,
                  padding: const EdgeInsets.only(left: 20,right: 20),
                  decoration: const BoxDecoration(
                    borderRadius: BorderRadius.only(bottomLeft: Radius.circular(40),bottomRight: Radius.circular(40)),
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Color(0xFFe5c958), // #e5c958
                        Color(0xFFc5a520), // #c5a520
                      ],
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            onTap: ()=> Get.back(),
                            child: Icon(Icons.arrow_back,color: Colors.white,size: width*0.08,),
                          ),
                          Text("$pageName Details",style: GoogleFonts.lato(
                              fontWeight: FontWeight.w400,
                              fontSize: width*0.06,
                              color: Colors.white
                          )),
                          Container(),
                        ],
                      ),
                    ],
                  )
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Task Name', style: GoogleFonts.lato(fontSize: 14, fontWeight: FontWeight.bold)),
                          Text(taskName, style: GoogleFonts.lato(fontSize: 14)),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Height * Width', style: GoogleFonts.lato(fontSize: 14, fontWeight: FontWeight.bold)),
                          Text("${data["height"]} * ${data["width"]}", style: GoogleFonts.lato(fontSize: 14)),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Area (in Sq. Meter)', style: GoogleFonts.lato(fontSize: 14, fontWeight: FontWeight.bold)),
                          Text("${data["area"]}", style: GoogleFonts.lato(fontSize: 14)),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Measured by', style: GoogleFonts.lato(fontSize: 14, color: Colors.grey.shade500)),
                          GestureDetector(
                              onTap: (){
                                if(data["image"] != null){
                                  Get.to(()=> AttachmentView(imagePath: data["image"], isNetwork: true));
                                }
                              },
                              child: Text(data["image"] == null ? "Manually" : "Image", style: GoogleFonts.lato(
                                  decoration: data["image"] == null ? null : TextDecoration.underline,
                                  fontSize: 14, color: Colors.grey.shade500))),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Total Cost', style: GoogleFonts.lato(fontSize: 14, fontWeight: FontWeight.bold)),
                          Text("R${data["cost"]}", style: GoogleFonts.lato(fontSize: 14)),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Description', style: GoogleFonts.lato(fontSize: 14, fontWeight: FontWeight.bold)),
                          Expanded(child: Text("R${data["description"]}", style: GoogleFonts.lato(fontSize: 14, color: Colors.grey.shade500), textAlign: TextAlign.end)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text('Attachments', style: GoogleFonts.lato(fontSize: 14, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 5),
                      StreamBuilder<QuerySnapshot>(
                          stream: FirebaseService.tasksManagementRef.doc(requestId).collection('images').where('job_id', isEqualTo: data["id"]).snapshots(),
                          builder: (context, snapshot){
                            if(!snapshot.hasData){
                              return Center(child: noText(text: 'No Image Available', align: TextAlign.start));
                            }
                            else {
                              if(snapshot.data!.docs.isEmpty){
                                return Center(child: noText(text: 'No Image Available', align: TextAlign.start));
                              }
                              else {
                                return SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  physics: const BouncingScrollPhysics(),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: List.generate(snapshot.data!.docs.length, (index){
                                      return Padding(
                                        padding: const EdgeInsets.only(right: 12),
                                        child: CommonWidget.buildImageFullSize(path: snapshot.data!.docs[index]["image_path"],
                                            height: height * 0.25, width: height * 0.25, isNetwork: true),
                                      );
                                    }),
                                  ),
                                );
                              }

                            }
                          }),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
