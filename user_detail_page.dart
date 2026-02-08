import 'dart:async';

import 'package:admain_maintence_app/controllers/app_controller.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../utily/buttons.dart';
import '../../utily/custom_card.dart';
import '../../utily/map_widget.dart';

class UserDetailPage extends StatefulWidget {
  final dynamic data;
  const UserDetailPage({super.key, this.data});

  @override
  State<UserDetailPage> createState() => _UserDetailPageState();
}

class _UserDetailPageState extends State<UserDetailPage> {
  final AppController appController = Get.find();
  final Completer<GoogleMapController> _controller = Completer<GoogleMapController>();
  final TextEditingController amountController = TextEditingController();

  @override
  void initState() {
    super.initState();
    appController.userAmount.value =
        (widget.data['balance'] ?? '0').toString();
  }

  Widget _personIcon() => Container(
        height: 40,
        width: 40,
        decoration: BoxDecoration(
          color: Colors.green.shade100,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: Colors.green.shade100),
        ),
        child: const Icon(Icons.person),
      );

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      appBar: AppBar(
        title: const Text("Detail Page"),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              const Text("Account Information"),
              Row(
                children: [
                  Expanded(
                    child: CustomCard(
                      title: "Balance",
                      widget: Obx(()=> Text(appController.userAmount.value)),
                    ),
                  ),
                  GestureDetector(
                    onTap: (){
                      amountController.text = "";
                      appController.transferAmount.value = "";
                      showDialog(
                          context: context,
                          builder: (BuildContext context) {
                            return AlertDialog(
                              title: Text(
                                "Add amount to ${widget.data['name']}'s Account",
                                  style: GoogleFonts.roboto(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: Card(
                                      elevation: 2,
                                      color: Colors.white,
                                      child: TextField(
                                        keyboardType: TextInputType.phone,
                                        controller: amountController,
                                        cursorColor: Colors.black,
                                        style: GoogleFonts.roboto(fontWeight: FontWeight.bold),
                                        decoration: InputDecoration(
                                          labelText: 'Amount',
                                          hintText: 'Enter Amount',
                                          hintStyle: GoogleFonts.roboto(color: const Color(0xffACADB9),
                                          fontSize: size.width * 0.04),
                                          labelStyle: GoogleFonts.roboto(
                                              color: const Color(0xffACADB9),
                                              fontSize: size.width * 0.04),
                                          border: InputBorder.none,
                                          focusedBorder: const OutlineInputBorder(
                                            borderSide: BorderSide(color: Colors.white),
                                          ),
                                          filled: true,
                                          fillColor: Colors.white,
                                          prefixIcon: Icon(
                                            Icons.currency_exchange,
                                            color: const Color(0xffACADB9),
                                            size: size.width * 0.07,
                                          ),
                                          contentPadding: const EdgeInsets.symmetric(
                                              vertical: 15.0, horizontal: 16.0),
                                        ),
                                        onChanged: (value){
                                          appController.transferAmount.value = value;
                                        },
                                      ),
                                    ),
                                  ),
                                  Obx(()=> appController.transferAmount.value == ""
                                      ? const SizedBox()
                                      : Text(
                                    "R${appController.transferAmount.value} will be added to ${widget.data['name']}'s Account",
                                  )),
                                  Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: PrimaryButton(
                                      color: Colors.green.shade900,
                                      onPressed: () async {
                                        var newAmount = (double.parse(widget.data['balance']) + double.parse(appController.transferAmount.value)).toString();
                                        appController.userAmount.value = newAmount;

                                        EasyLoading.show(status: "Please wait");
                                        await appController.userRef.doc(widget.data['uid']).update({
                                              "balance" : newAmount});

                                        appController.transferAmount.value = "";

                                        EasyLoading.dismiss();
                                        Navigator.pop(context);
                                      },
                                      title: "Add Amount",
                                    ),
                                  )
                                ],
                              ),
                            );
                          });
                    },
                    child: Container(
                      margin: const EdgeInsets.only(left: 5),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                          color: Colors.green.shade100,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: Colors.green.shade100)
                      ),
                      child: Row(
                        children: [
                          Text('Add Balance', style: TextStyle(color: Colors.green.shade900)),
                          Icon(Icons.add_box_outlined, color: Colors.green.shade900)
                        ],
                      ),
                    ),
                  )
                ],
              ),
              const SizedBox(height: 20),
              const Text("Other Information"),
              CustomCard(
                title: "Name",
                widget: Text(widget.data['name']),
              ),
              CustomCard(
                title: "Email",
                widget: Text(widget.data['email']),
              ),
              CustomCard(
                  title: "Location",
                  widget: SizedBox(
                    height: 150,
                    child: MapWidget(
                      data: widget.data,
                      onMapCreated: (GoogleMapController controller) {
                        _controller.complete(controller);
                      },
                    ),
                  )),
              CustomCard(
                title: "Previous Orders",
                widget: StreamBuilder(
                    stream: appController.tasksManagementRef
                        .where('user_id',
                            isEqualTo:
                                (widget.data["uid"] ?? widget.data.id ?? '')
                                    .toString())
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(
                            child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError) {
                        return Center(
                            child: noText(text: 'Error loading orders'));
                      }
                      if (!snapshot.hasData ||
                          snapshot.data == null ||
                          snapshot.data!.docs.isEmpty) {
                        return Center(
                            child: noText(text: 'No Order Available'));
                      }
                      debugPrint("order ${snapshot.data!.docs.length}");
                      return SizedBox(
                        height: size.height * 0.35,
                        child: ListView.separated(
                          itemCount: snapshot.data!.docs.length,
                          shrinkWrap: true,
                          itemBuilder: (context, index) {
                            final data = snapshot.data!.docs[index];
                            final spId = (data["service_provider_id"] ?? '')
                                .toString()
                                .trim();
                            final tId =
                                (data["task_id"] ?? '').toString().trim();

                            // If no service_provider_id, show basic info
                            if (spId.isEmpty) {
                              return ListTile(
                                leading: Container(
                                  height: 40,
                                  width: 40,
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: const Icon(Icons.person_outline),
                                ),
                                title: const Text('Unassigned'),
                                subtitle:
                                    Text(data['description'] ?? 'N/A'),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        "Rate: ${data['cost'] ?? 'N/A'}"),
                                    Text(
                                        "Status: ${data['status'] ?? 'N/A'}"),
                                  ],
                                ),
                              );
                            }

                            return StreamBuilder(
                                stream: appController.serviceProviderRef
                                    .doc(spId)
                                    .snapshots(),
                                builder: (context, spSnapshot) {
                                  if (!spSnapshot.hasData) {
                                    return const ListTile(
                                        title: Text('Loading...'));
                                  }
                                  final spDoc = spSnapshot.data;
                                  final spExists =
                                      spDoc != null && spDoc.exists;
                                  final spData = spExists
                                      ? spDoc.data()
                                          as Map<String, dynamic>?
                                      : null;

                                  final spName =
                                      spData?['name'] ?? 'Unknown';
                                  final spImage =
                                      (spData?['image'] ?? '').toString();

                                  return ListTile(
                                    leading: ClipRRect(
                                      borderRadius:
                                          BorderRadius.circular(15),
                                      child: spImage.isNotEmpty
                                          ? Image.network(
                                              spImage,
                                              height: 40,
                                              width: 40,
                                              fit: BoxFit.cover,
                                              errorBuilder:
                                                  (_, __, ___) =>
                                                      _personIcon(),
                                            )
                                          : _personIcon(),
                                    ),
                                    title: Text(spName.toString(),
                                        textAlign: TextAlign.start),
                                    subtitle: tId.isNotEmpty
                                        ? StreamBuilder(
                                            stream: appController.taskRef
                                                .doc(tId)
                                                .snapshots(),
                                            builder: (context, snp) {
                                              if (!snp.hasData ||
                                                  snp.data == null ||
                                                  !snp.data!.exists) {
                                                return Text(data[
                                                        'task_name'] ??
                                                    data[
                                                        'description'] ??
                                                    'N/A');
                                              }
                                              final taskData =
                                                  snp.data!.data()
                                                      as Map<String,
                                                          dynamic>?;
                                              return Text(
                                                  taskData?['name'] ??
                                                      'N/A');
                                            },
                                          )
                                        : Text(
                                            data['task_name'] ??
                                                data['description'] ??
                                                'N/A'),
                                    trailing: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                            "Rate: ${data['cost'] ?? 'N/A'}"),
                                        Text(
                                            "Rating: ${(data['rating'] == null || data['rating'] == '') ? 'N/A' : data['rating']}"),
                                      ],
                                    ),
                                  );
                                });
                          },
                          separatorBuilder:
                              (BuildContext context, int index) {
                            return const Divider();
                          },
                        ),
                      );
                    }),
              ),
              CustomCard(
                  title: "Delete",
                  widget: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: PrimaryButton(
                      onPressed: () async {
                        EasyLoading.show(status: "Please wait");
                        await FirebaseFirestore.instance.collection('users').doc(widget.data['uid']).delete();
                        EasyLoading.dismiss();
                        Navigator.pop(context);
                      },
                      title: "Delete",
                    ),
                  )),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}


Widget noText({String? text, TextAlign? align})=> Text(text ?? "N/A", textAlign: align ?? TextAlign.end, style: const TextStyle(
  color: Colors.black,
  fontWeight: FontWeight.w500,
  fontSize: 15,
));