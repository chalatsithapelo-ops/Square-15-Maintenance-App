import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'package:maintenanceapp/screens/home/booking/attachment_view.dart';
import 'package:maintenanceapp/screens/home/booking/google_map_view.dart';
import 'package:maintenanceapp/screens/home/payment_method_view.dart';
import 'package:maintenanceapp/screens/service_provider_panel/service_provider_request_screen.dart';
import 'package:maintenanceapp/services/firestore_services/firebase_services.dart';
import 'package:maintenanceapp/utils/dotted_line.dart';
import 'package:maintenanceapp/utils/helper.dart';
import 'package:maintenanceapp/utils/navigation.dart';
import 'package:maintenanceapp/utils/primary_button.dart';

import 'booking_detail_page.dart';
import 'chat_screen.dart';
import 'create_future_booking_screen.dart';
import 'future_bookings_list_screen.dart';

class booking extends StatefulWidget {
  const booking({super.key});

  @override
  State<booking> createState() => _bookingState();
}

class _bookingState extends State<booking> {



  int _currentPage = 0;
  final _pageController = PageController();
  final AppController appController = Get.find();
  late Stream<QuerySnapshot<Map<String, dynamic>>> query;

  @override
  void initState() {

    super.initState();
    query = FirebaseService.tasksManagementRef
        .where('accept', whereIn: ["","0","1"])
        .where('status', isNotEqualTo: 'closed')
        .where('user_id', isEqualTo: appController.userId.value)
        .orderBy('creation_date', descending: true)
        .snapshots();

  }





  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }



  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              height: height * 0.15,
              padding: const EdgeInsets.only(left: 20, right: 20),
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(40),
                  bottomRight: Radius.circular(40),
                ),
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color(0xFFe5c958), // #e5c958
                    Color(0xFFc5a520), // #c5a520
                  ],
                ),
              ),
              child: Center(
                child: Text(
                  'Booking',
                  style: GoogleFonts.roboto(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: width * 0.06,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Column(
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GestureDetector(
                          onTap: () {
                            setState(() => _currentPage = 0);
                            query = FirebaseService.tasksManagementRef
                                .where('accept', whereIn: ["","0","1"])
                                .where('status', isNotEqualTo: 'closed')
                                .where('user_id', isEqualTo: appController.userId.value)
                                .orderBy('creation_date', descending: true)
                                .snapshots();
                          },
                          child: Container(
                            alignment: Alignment.center,
                            height: height*0.06,
                            width: width*0.25,
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                                color: _currentPage == 0
                                    ?  const Color(0xFFc5a520)
                                    : const Color(0xff868686),
                              borderRadius: BorderRadius.circular(5)
                            ),
                            child: Text('Current', style: GoogleFonts.roboto(
                                color: Colors.white,
                                fontWeight: FontWeight.w400,
                                fontSize: width*0.05
                            ),),
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: () {
                            setState(() => _currentPage = 1);
                            query = FirebaseService.tasksManagementRef
                                .where('accept', whereIn: ["","0","1"])
                                .where('status', isEqualTo: "closed")
                                .where('user_id', isEqualTo: appController.userId.value)
                                .orderBy('creation_date', descending: true)
                                .snapshots();
                          },
                          child: Container(
                            alignment: Alignment.center,
                            height: height*0.06,
                            width: width*0.25,
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                                color: _currentPage == 1
                                    ?  const Color(0xFFc5a520)
                                    : const Color(0xff868686),
                                borderRadius: BorderRadius.circular(5)
                            ),
                            child: Text('Past', style: GoogleFonts.roboto(
                                color: Colors.white,
                                fontWeight: FontWeight.w400,
                                fontSize: width*0.05
                            ),),
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: () {
                            setState(() => _currentPage = 2);
                          },
                          child: Container(
                            alignment: Alignment.center,
                            height: height*0.06,
                            width: width*0.25,
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                                color: _currentPage == 2
                                    ?  const Color(0xFFc5a520)
                                    : const Color(0xff868686),
                                borderRadius: BorderRadius.circular(5)
                            ),
                            child: Text('Future', style: GoogleFonts.roboto(
                                color: Colors.white,
                                fontWeight: FontWeight.w400,
                                fontSize: width*0.05
                            ),),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _currentPage == 2 
                        ? const FutureBookingsListScreen()
                        : GeneralMaintenancePage(queryBy: query),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _currentPage == 2
          ? FloatingActionButton.extended(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const CreateFutureBookingScreen(),
                  ),
                );
              },
              backgroundColor: const Color(0xFFc5a520),
              icon: const Icon(Icons.add, color: Colors.white),
              label: Text('Schedule', style: GoogleFonts.roboto(color: Colors.white)),
            )
          : null,
    );
  }
}

class GeneralMaintenancePage extends StatelessWidget {
  final Stream<QuerySnapshot<Map<String, dynamic>>> queryBy;
  const GeneralMaintenancePage({super.key, required this.queryBy});

  @override
  Widget build(BuildContext context) {
    final AppController appController = Get.find();
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    final TextEditingController feedBackController = TextEditingController();
    return Scaffold(
      body:  StreamBuilder(
          stream: queryBy,
          builder: (context,snapshot){
            debugPrint("record ${snapshot.data != null ? snapshot.data!.docs.length : "N/A"}");
            if(!snapshot.hasData){
              return Center(child: noText(text: 'No Request Available'));
            }
            else {
              final filteredDocs = snapshot.data!.docs.where((d) {
                final data = d.data();
                final source = (data['source'] ?? '').toString().trim().toLowerCase();
                // Future bookings are shown under the "Future" tab, not Current/Past.
                return source != 'future_booking';
              }).toList(growable: false);

              return filteredDocs.isNotEmpty
                  ? ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    itemCount: filteredDocs.length,
                    itemBuilder: (context, index){
                      TaskManagementModel record = TaskManagementModel.fromDocument(filteredDocs[index].data());
                      final diff = DateTime.now().difference(DateTime.parse(record.updatedAt!));
                      final minutes = diff.inMinutes;
                      final hours = diff.inHours;
                      final days = diff.inDays;
                      final months = (days / 30).floor();
                      return Container(
                          width: double.infinity,
                          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: Colors.white,
                            // border: Border.all(color: Colors.grey, width: 0.2)
                            boxShadow: [
                              BoxShadow(
                                color: Colors.grey.shade300,
                                offset: const Offset(1, 1),
                                spreadRadius: 0.3,
                              ),
                              BoxShadow(
                                color: Colors.grey.shade300,
                                offset: const Offset(-1, -1),
                                spreadRadius: 0.3,
                              ),
                            ]
                          ),
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            minLeadingWidth: 50,
                            // leading: CircleAvatar(
                            //   radius: 30,
                            //   backgroundImage:
                            //   AssetImage("assets/images/artisan.png"),
                            // ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text("Order No. #", style: GoogleFonts.lato(fontSize: 12, fontWeight: FontWeight.bold)),
                                    Text(record.orderNo.toString(), style: GoogleFonts.lato(fontSize: 12)),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("Task Created for following jobs", style: GoogleFonts.lato(fontSize: 12)),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text('Last Updated', style: GoogleFonts.lato(fontSize: 12)),
                                            Text(minutes <= 59
                                                ? "$minutes minutes ago"
                                                : hours <= 24
                                                ? "$hours hours ago"
                                                : days < 30
                                                ? "$days day${days > 1 ? 's' : ''} ago"
                                                : "$months month${months > 1 ? 's' : ''} ago",
                                            style: GoogleFonts.lato(fontSize: 12),
                                          ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                StreamBuilder<QuerySnapshot>(
                                    stream: FirebaseService.tasksManagementRef.doc(record.id).collection('jobs').snapshots(),
                                    builder: (context, snapshot){
                                      if(!snapshot.hasData){
                                        return Center(child: noText(align: TextAlign.start));
                                      }
                                      else {
                                        if(snapshot.data!.docs.isEmpty){
                                          return noText(align: TextAlign.start);
                                        }
                                        else {
                                          return SingleChildScrollView(
                                            scrollDirection: Axis.horizontal,
                                            child: Row(
                                              children: List.generate(snapshot.data!.docs.length, (index){
                                                return  StreamBuilder(
                                                    stream: FirebaseService.taskRef.doc(snapshot.data!.docs[index]["task_id"]).snapshots(),
                                                    builder: (context, taskSnapshot){
                                                      if(!taskSnapshot.hasData){
                                                        return Center(child: noText(align: TextAlign.start));
                                                      }
                                                      else {
                                                        if(taskSnapshot.data!.data() == null){
                                                          return Center(child: noText(align: TextAlign.start));
                                                        }
                                                        else {
                                                          return GestureDetector(
                                                            onTap: (){
                                                              debugPrint("clicked");
                                                              Get.to(()=> BookingDetailPage(
                                                                  pageName: 'Booking',
                                                                  requestId: record.id.toString(),
                                                                  data: snapshot.data!.docs[index],
                                                                  taskName: taskSnapshot.data!.data()!["name"]));
                                                            },
                                                            child: Container(
                                                              padding: EdgeInsets.all(8),
                                                              margin: const EdgeInsets.only(right: 8, bottom: 5),
                                                              decoration: BoxDecoration(
                                                                  borderRadius: BorderRadius.circular(8),
                                                                  color: Colors.white,
                                                                  boxShadow: [
                                                                    BoxShadow(
                                                                        color: Colors.grey.shade200,
                                                                        offset: const Offset(1, 1),
                                                                        spreadRadius: 2,
                                                                        blurRadius: 2
                                                                    )
                                                                  ]
                                                              ),
                                                              child: Column(
                                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                                children: [
                                                                  Container(
                                                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                                                    margin: const EdgeInsets.only(right: 8, bottom: 5),
                                                                    decoration: BoxDecoration(
                                                                      color: Colors.grey.shade100,
                                                                      borderRadius: BorderRadius.circular(3),
                                                                      border: Border.all(color: Colors.grey.shade700)
                                                                    ),
                                                                    child: Row(
                                                                      children: [
                                                                        Container(
                                                                          margin: const EdgeInsets.only(right: 5),
                                                                          padding: const EdgeInsets.all(5),
                                                                          decoration: BoxDecoration(color: Colors.grey.shade500, shape: BoxShape.circle),
                                                                        ),
                                                                        Text(taskSnapshot.data!.data()!["name"] ?? "N/A",textAlign: TextAlign.start,
                                                                          style: GoogleFonts.lato(fontSize: 14, color: Colors.grey.shade700, fontWeight: FontWeight.w600)),
                                                                      ],
                                                                    ),
                                                                  ),
                                                                  snapshot.data!.docs[index]["description"] == "" || snapshot.data!.docs[index]["description"] == null
                                                                      ? SizedBox.shrink()
                                                                      : Text(snapshot.data!.docs[index]["description"] ?? "N/A",
                                                                      textAlign: TextAlign.start, style: GoogleFonts.lato(fontSize: 12, color: Colors.grey.shade700)),
                                                                  snapshot.data!.docs[index]["cost"] == "" || snapshot.data!.docs[index]["cost"] == null
                                                                      ? SizedBox.shrink()
                                                                      : Text(snapshot.data!.docs[index]["cost"] == null ? "" : "R${snapshot.data!.docs[index]["cost"]}",
                                                                      textAlign: TextAlign.start, style: GoogleFonts.lato(fontSize: 12, color: Colors.grey.shade700)),
                                                                ],
                                                              ),
                                                            ),
                                                          );
                                                        }
                                                      }
                                                    });
                                              }),
                                            ),
                                          );
                                        }

                                      }
                                    }),
                                const SizedBox(height: 5),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        Text("Total Cost: ", style: GoogleFonts.lato(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black)),
                                        Text(record.cost == null ? "N/A" : "R${record.cost}", style: GoogleFonts.lato(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black)),
                                      ],
                                    ),
                                    ///chatting
                                    record.accept == "1" && record.status == "progress"
                                        ? ChatIconWidget(record: record)
                                        : const SizedBox()
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    const Text("Status: "),
                                    Container(
                                      padding: const EdgeInsets.all(4),
                                      decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(5),
                                          color: record.status == "closed"
                                              ? Colors.grey.shade100
                                              : record.status == "completed"
                                              ? Colors.grey.shade100
                                              : record.accept == "1"
                                              ? Colors.green.shade100
                                              : record.accept == "0"
                                              ? Colors.red.shade100
                                              : Colors.amber.shade100,
                                          border: Border.all(color:
                                          record.status == "closed"
                                              ? Colors.grey
                                              : record.status == "completed"
                                              ? Colors.grey
                                              : record.accept == "1"
                                              ? Colors.green.shade900
                                              : record.accept == "0"
                                              ? Colors.red.shade900
                                              : Colors.amber.shade900)
                                      ),
                                      child: Text(
                                        record.status == "closed"
                                            ? "closed"
                                            : record.status == "completed"
                                            ? "completed"
                                            : record.status == "progress"
                                            ? "On Progress"
                                            : record.accept == "1"
                                            ? "Accepted"
                                            : record.accept == "0"
                                            ? "Rejected"
                                            : "Pending to Artisan",
                                        style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                            color: record.status == "closed"
                                                ? Colors.grey
                                                : record.status == "completed"
                                                ? Colors.grey
                                                : record.accept == "1"
                                                ? Colors.green.shade900
                                                : record.accept == "0"
                                                ? Colors.red.shade900
                                                : Colors.amber.shade900
                                        ),
                                      ),
                                    ),
                                    record.paymentStatus == "paid" ? const Text(' (Payment Transferred)') : const SizedBox(),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Row(
                                  children: [
                                    const Text("Created at: "),
                                    Text(DateFormat('dd/MMM/yyyy hh:mm a').format(DateTime.parse(record.creationDate!))),
                                  ],
                                ),
                                // Text(record.description == "" ? "" : "\"${record.description}\"",
                                //     style: const TextStyle(color: Colors.black)),
                                // const SizedBox(height: 5),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    record.attachment == null || record.attachment == ""
                                        ? const SizedBox()
                                        : GestureDetector(
                                          onTap: (){
                                            Get.to(()=> AttachmentView(imagePath: record.attachment!));
                                          },
                                          child: Row(
                                            mainAxisAlignment: MainAxisAlignment.end,
                                            children: [
                                              Icon(Icons.attachment, color: Colors.amber.shade500),
                                              const SizedBox(width: 5),
                                              Text('Attachment', style: GoogleFonts.lato(fontWeight: FontWeight.w700,
                                                  color: Colors.amber.shade500, fontSize: 14)),
                                            ],
                                          )),
                                    record.additionalAttachment == null || record.additionalAttachment == ""
                                        ? const SizedBox()
                                        : GestureDetector(
                                          onTap: (){
                                            Get.to(()=> AttachmentView(imagePath: record.additionalAttachment!));
                                          },
                                          child: Row(
                                            mainAxisAlignment: MainAxisAlignment.end,
                                            children: [
                                              Icon(Icons.attachment, color: Colors.amber.shade500),
                                              const SizedBox(width: 5),
                                              Text('Additional attachment', style: GoogleFonts.lato(fontWeight: FontWeight.w700,
                                                  color: Colors.amber.shade500, fontSize: 14)),
                                            ],
                                          )),
                                  ],
                                ),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    record.description == "" || record.description == null
                                        ? const SizedBox() : descriptionWidget(height, record.description),
                                    record.additionalDescription == null || record.additionalDescription == ""
                                        ? const SizedBox() : descriptionWidget(height, record.additionalDescription),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                record.accept == "1" && record.paymentStatus == "" && record.status != "closed" && record.status != "completed"
                                    ? GestureDetector(
                                      onTap: () async {
                                        // appController.isWithdraw.value = false;
                                        appController.getUser(id: appController.userId.value);
                                        showModalBottomSheet(
                                          shape: const RoundedRectangleBorder(
                                            borderRadius: BorderRadius.only(
                                                topLeft: Radius.circular(16), topRight: Radius.circular(16)
                                            ),
                                          ),
                                          context: context,
                                          builder: (BuildContext context) {
                                            return ModelBottomSheet(record: record);
                                          },
                                        );



                                      },
                                      child: Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: Colors.blue,
                                          borderRadius: BorderRadius.circular(5),
                                        ),
                                        child: const Text('Pay to confirm Order', style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.white
                                        ),),
                                      ),
                                    )
                                    : record.accept == "1" && record.paymentStatus == "paid" && record.status != "completed" && record.artisanImages == "2"
                                    ? Column(
                                      children: [
                                        Container(
                                          // height: height * 0.25,
                                          padding: const EdgeInsets.all(4),
                                          margin: const EdgeInsets.only(bottom: 5),
                                          width: width,
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            border: Border.all(color: Colors.grey)
                                          ),
                                          child: StreamBuilder(
                                              stream: appController.artisanTaskImages.doc(record.artisanImageDocId).snapshots(),
                                              builder: (context, workImageSnapshot){
                                                if(!workImageSnapshot.hasData){
                                                  return const SizedBox();
                                                }
                                                else {
                                                  return  Row(
                                                    children: [
                                                      Expanded(
                                                        child: Column(
                                                          crossAxisAlignment: CrossAxisAlignment.start,
                                                          children: [
                                                            Text("Before:\n'${workImageSnapshot.data!["before_notes"]}'", style: GoogleFonts.lato(fontSize: 12)),
                                                            Text("Date:\n${Helper.formatDateTime(date: workImageSnapshot.data!["created_at"])}", style: GoogleFonts.lato(fontSize: 12)),
                                                            workImageSnapshot.data!["before_work"] == ""
                                                                ? const SizedBox()
                                                                : GestureDetector(
                                                                  onTap: (){
                                                                    Get.to(()=> AttachmentView(imagePath: workImageSnapshot.data!["before_work"]));
                                                                  },
                                                                  child: Text('Before Work Image', style: GoogleFonts.lato(fontWeight: FontWeight.w700,
                                                                    color: Colors.amber.shade500, fontSize: 12))),
                                                          ],
                                                        ),
                                                      ),
                                                      Expanded(
                                                        child: Column(
                                                          crossAxisAlignment: CrossAxisAlignment.start,
                                                          children: [
                                                            Text("After:\n'${workImageSnapshot.data!["after_notes"]}'", style: GoogleFonts.lato(fontSize: 12)),
                                                            Text("Date:\n${Helper.formatDateTime(date: workImageSnapshot.data!["updated_at"])}", style: GoogleFonts.lato(fontSize: 12)),
                                                            workImageSnapshot.data!["after_work"] == ""
                                                                ? const SizedBox()
                                                                : GestureDetector(
                                                                  onTap: (){
                                                                    Get.to(()=> AttachmentView(imagePath: workImageSnapshot.data!["after_work"]));
                                                                  },
                                                                  child: Text('After Work Image', style: GoogleFonts.lato(fontWeight: FontWeight.w700,
                                                                    color: Colors.amber.shade500, fontSize: 12))),
                                                          ],
                                                        ),
                                                      ),
                                                    ],
                                                  );
                                                }
                                              }),
                                        ),
                                        GestureDetector(
                                          onTap: () async {
                                            double userRating = 0.0;
                                            showDialog(
                                              context: context,
                                              builder: (context) {
                                                return AlertDialog(
                                                  title: const Text('Rate Artisan'),
                                                  content: Column(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: <Widget>[
                                                      const Text('Enter your feedback:'),
                                                      const SizedBox(height: 20),
                                                      ClipRRect(
                                                        borderRadius: BorderRadius.circular(10),
                                                        child: Card(
                                                          elevation: 2,
                                                          color: Colors.white,
                                                          child: TextField(
                                                            maxLines: 5,
                                                            controller: feedBackController,
                                                            cursorColor: Colors.black,
                                                            style: GoogleFonts.roboto(fontWeight: FontWeight.normal),
                                                            decoration: InputDecoration(
                                                              labelText: 'Comment',
                                                              labelStyle: GoogleFonts.roboto(
                                                                  color: const Color(0xffACADB9),
                                                                  fontSize: width * 0.04),
                                                              border: InputBorder.none,
                                                              focusedBorder: const OutlineInputBorder(
                                                                borderSide: BorderSide(color: Colors.white),
                                                              ),
                                                              filled: true,
                                                              fillColor: Colors.white,
                                                              prefixIcon: Icon(
                                                                Icons.comment,
                                                                color: const Color(0xffACADB9),
                                                                size: width * 0.07,
                                                              ),
                                                              contentPadding: const EdgeInsets.symmetric(
                                                                  vertical: 15.0, horizontal: 16.0),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                      const SizedBox(height: 20),
                                                      RatingBar.builder(
                                                        initialRating: 0,
                                                        minRating: 1,
                                                        direction: Axis.horizontal,
                                                        // allowHalfRating: true,
                                                        itemCount: 5,
                                                        itemPadding: const EdgeInsets.symmetric(horizontal: 1.0),
                                                        itemBuilder: (context, _) => const Icon(
                                                          Icons.star,
                                                          color: Colors.amber,
                                                        ),
                                                        onRatingUpdate: (rating) {
                                                          userRating = rating;

                                                          /// for average of rating
                                                          // if(record.rating != ""){
                                                          //   userRating = double.parse(record.rating!);
                                                          // }
                                                          // userRating = (rating + userRating ) / 2;
                                                        },
                                                      ),
                                                    ],
                                                  ),
                                                  actions: <Widget>[
                                                    TextButton(
                                                      onPressed: () {
                                                        Navigator.of(context).pop();
                                                      },
                                                      child: const Text('Cancel'),
                                                    ),
                                                    TextButton(
                                                      onPressed: () {
                                                        Navigator.of(context).pop();
                                                        // Handle the user's feedback and rating here
                                                        debugPrint('Feedback: ${feedBackController.text}');
                                                        debugPrint('Rating: $userRating');

                                                        EasyLoading.show(status: 'Please Wait...!');
                                                        appController.markOrderAsCompleted(
                                                            rating: userRating.toString(),
                                                            feedback: feedBackController.text.trArgs(),
                                                            taskManagementId: record.id!).then((_){
                                                          EasyLoading.dismiss();
                                                        });
                                                      },
                                                      child: const Text('Submit'),
                                                    ),
                                                  ],
                                                );
                                              },
                                            );

                                          },
                                          child: Container(
                                            padding: const EdgeInsets.all(6),
                                            decoration: BoxDecoration(
                                                color: const Color(0xFFc5a520).withOpacity(0.2),
                                                borderRadius: BorderRadius.circular(5),
                                                border: Border.all(color: const Color(0xFFc5a520))
                                            ),
                                            child: const Row(
                                              children: [
                                                Text('Press to Complete order', style: TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w500,
                                                    color: Color(0xFFc5a520)
                                                )),
                                                SizedBox(width: 5),
                                                Icon(Icons.verified_outlined, color: Color(0xFFc5a520),)
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                    : const SizedBox(),
                                const SizedBox(height: 10),
                                CustomPaint(
                                  size: Size(width, height*0.01),
                                  painter: DottedLinePainter(Colors.grey.shade700),
                                ),
                                const SizedBox(height: 10),
                                StreamBuilder(
                                    stream: FirebaseService.providerRef.doc(record.serviceProviderId).snapshots(),
                                    builder: (context, snapshot){
                                      if(!snapshot.hasData){
                                        return Center(child: noText(align: TextAlign.start));
                                      }
                                      else {
                                        if(snapshot.data!.data() == null){
                                          return Center(child: noText(align: TextAlign.start));
                                        }
                                        else {
                                          return Column(
                                            children: [
                                              Row(
                                                children: [
                                                  snapshot.data!.data()!["image"] == ""
                                                      ? ClipRRect(
                                                        borderRadius: BorderRadius.circular(50.0),
                                                        child: SizedBox(
                                                            height: MediaQuery.of(context).size.width*0.1, width: MediaQuery.of(context).size.width*0.1,
                                                            child: Image.asset('assets/images/no_image.png',fit: BoxFit.cover)),
                                                      )
                                                      : ClipRRect(
                                                        borderRadius: BorderRadius.circular(50.0),
                                                        child: SizedBox(
                                                            height: MediaQuery.of(context).size.width*0.1, width: MediaQuery.of(context).size.width*0.1,
                                                            child: Image.network(snapshot.data!.data()!["image"],fit: BoxFit.cover)),
                                                      ),
                                                  const SizedBox(width: 10),
                                                  Text(snapshot.data!.data()!["name"] ?? "N/A",textAlign: TextAlign.start,
                                                    style: const TextStyle(color: Colors.black,fontSize: 16, fontWeight: FontWeight.w700),),
                                                  const Spacer(),
                                                  Text('R${record.cost}'),
                                                ],
                                              ),
                                              record.status == "progress"
                                                  ? GestureDetector(
                                                      onTap: (){
                                                        navigateToPage(context: context, pageName: GoogleMapView(id: record.serviceProviderId!,
                                                            taskRecord: record,
                                                            name: snapshot.data!.data()!["name"]));
                                                      },
                                                      child: Container(
                                                        margin: const EdgeInsets.only(top: 10),
                                                        padding: const EdgeInsets.all(5),
                                                        decoration: BoxDecoration(
                                                            color: Colors.amber.shade50,
                                                            borderRadius: BorderRadius.circular(5),
                                                            border: Border.all(color: Colors.amber.shade300),
                                                            boxShadow: [
                                                              BoxShadow(
                                                                color: Colors.grey.shade200,
                                                                blurRadius: 0.5, spreadRadius: 0.5,

                                                              )
                                                            ]
                                                        ),
                                                        child: Row(
                                                          mainAxisAlignment: MainAxisAlignment.center,
                                                          children: [
                                                            Text('Track Artisan', style: GoogleFonts.lato(fontWeight: FontWeight.w700,
                                                                color: Colors.amber.shade500, fontSize: 16)),
                                                            const SizedBox(width: 10),
                                                            Image.asset('assets/images/track.png', height: 30)
                                                            // Icon(Icons.map_outlined)
                                                          ],
                                                        ),
                                                      ))
                                                  : const SizedBox()
                                            ],
                                          );
                                        }

                                      }
                                    }),

                              ],
                            ),
                          ));
                    })
                  : Center(child: noText(text: 'No Request Available'));
            }
          })
    );
  }
}

class BusinessPage extends StatelessWidget {
  const BusinessPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: Image.asset('assets/images/book/Group 1261152605.png')
    );
  }
}

class ModelBottomSheet extends StatefulWidget {
  final TaskManagementModel record;
  const ModelBottomSheet({super.key, required this.record});

  @override
  _ModelBottomSheetState createState() => _ModelBottomSheetState();
}

class _ModelBottomSheetState extends State<ModelBottomSheet> {

  final AppController appController = Get.find();
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [

            Text('Select Your Payment Method', style: GoogleFonts.lato(fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 20),
            PrimaryButton(
              onPressed: () async {
                appController.isPaymentUsingPayFast.value = false;
                debugPrint("data ${widget.record.toMap().toString()}");
                debugPrint("id ${widget.record.id}");
                EasyLoading.dismiss();
                EasyLoading.show(status: "Please Wait...!");
                appController.getUser(id: appController.userId.value).then((value) async {
                  if(widget.record.cost != null) {
                    if(double.parse(widget.record.cost.toString()) < double.parse(appController.userBalance.value)){
                      appController.savePaymentStatus(cost: widget.record.cost!, taskManagementId: widget.record.id!, status: 'success').then((_){
                        debugPrint('idr');
                        EasyLoading.dismiss();
                        Future.delayed(const Duration(seconds: 2),(){
                          debugPrint('idr tak ...........');
                          Navigator.of(context).pop();
                        });
                      });
                    }
                    else{
                      Get.showSnackbar(
                          GetSnackBar(
                            backgroundColor: Colors.red.shade900,
                            duration: const Duration(seconds: 4),
                            snackPosition: SnackPosition.TOP,
                            title: 'Sorry', message:'Balance is low! Contact to Admin',));
                      EasyLoading.dismiss();
                      Navigator.of(context).pop();
                    }
                  }
                  else{
                    EasyLoading.dismiss();
                  }
                });
              },
              title: "Pay Via Wallet",
            ),
            const SizedBox(height: 20),
            PrimaryButton(
              onPressed: () async {
                appController.isPaymentUsingPayFast.value = true;
                EasyLoading.show(status: "Please Wait...!");
                await appController.getUser(id: appController.userId.value).then((value) async {
                  if(widget.record.cost != null) {
                    appController.webUrl.value = await appController.initiatePayment(cost: widget.record.cost!);
                    Get.to(()=> PaymentMethodView(taskManagementModel : widget.record), transition: Transition.fadeIn);
                  }
                });
                EasyLoading.dismiss();

              },
              title: "Pay Via PayFast (credit or debit card)",
            ),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }
}

Widget descriptionWidget(height, String? text)=> Expanded(
    child: Container(
        height: text != null && text.length > 50 ? height * 0.15 : null,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.grey.shade300, width: 1)
        ),
        child: SingleChildScrollView(child: Text(text ?? ""))));


class ChatIconWidget extends StatelessWidget {
  final TaskManagementModel record;
  final bool isArtisanSide;
  const ChatIconWidget({super.key, required this.record, this.isArtisanSide = false});

  @override
  Widget build(BuildContext context) {
    final AppController appController = Get.find();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topRight,
          children: [
            GestureDetector(
              onTap: ()=> Get.to(()=> ChatScreen(task: record, isArtisanSide: isArtisanSide)),
              child: Container(
                  padding: EdgeInsets.all(4),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.grey)
                  ),
                  child: Icon(Icons.message, color: Colors.grey.shade500)),
            ),
            StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection("tasksManagement")
                    .doc(record.id)
                    .collection("chat")
                    .where("receiver_id", isEqualTo: appController.userId.value) // Only messages for me
                    .where("isRead", isEqualTo: false)              // Only unread
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return SizedBox();
                  }
                  else if (!snapshot.hasData) {
                    return SizedBox();
                  }
                  int unreadCount = snapshot.data!.docs.length;
                  if(unreadCount != 0){
                    return Positioned(
                      top: -15,
                      right: -10,
                      child: Container(
                        padding: EdgeInsets.all(6),
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.red
                        ),
                        child: Text(unreadCount.toString(), style: TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                    );
                  }
                  return SizedBox();
                }
            )
          ],
        ),
        Text("Chat", style:  GoogleFonts.lato(fontSize: 12))
      ],
    );
  }
}

