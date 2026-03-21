import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/screens/auth/login.dart';
import 'package:maintenanceapp/screens/home/dashboard/sub_category_screen.dart';
import 'package:maintenanceapp/services/firestore_services/firebase_services.dart';
import 'package:maintenanceapp/utils/navigation.dart';


class Dashboard extends StatefulWidget {
   const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {

  final AppController appController = Get.find();

  String name = '';
  int currentImageIndex = 0;

  Future<void> getUser() async {
    if(FirebaseAuth.instance.currentUser == null){
      navigateToPage(context: context, pageName: const Login());
    }else{
      DocumentSnapshot snp = await FirebaseFirestore.instance.collection("users").doc(FirebaseAuth.instance.currentUser!.uid).get();
      setState(() {
        name = snp["name"];
      });
    }

  }

  @override
  void initState() {

    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await getUser();
      appController.getCurrentPosition(context);
    });

  }

  final List<DashboardItem> items = [
    DashboardItem(
      color: const Color(0xff85E2FF),
    ),
    DashboardItem(
      color: const Color(0xff8BE1A3),
    ),
    DashboardItem(
      color: const Color(0xffFFCB9C),
    ),
    DashboardItem(
      color: const Color(0xffF4B4FF),
    ),
    DashboardItem(
      color: const Color(0xffFFA9A9),
    ),
    DashboardItem(
      color: const Color(0xff81D0C2),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            height: height * 0.15,
            padding: const EdgeInsets.only(left: 20, right: 20, bottom: 20),
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
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  DateTime.now().hour<11?
                  'Good Morning, $name!':
                  DateTime.now().hour>11 && DateTime.now().hour<16?
                  'Good Afternoon, $name!':
                  DateTime.now().hour>16 && DateTime.now().hour<20?
                  'Good Evening, $name!':
                  'Good Night, $name!',
                  style: GoogleFonts.roboto(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                    fontSize: width * 0.05,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20), // Add horizontal padding
              child: StreamBuilder(
                  stream: FirebaseService.categoryRef
                      .where('parent_id',isEqualTo: "")
                      .where('status', whereIn: ['publish', 'coming_soon'])
                      .snapshots(),
                  builder: (context, snapshot){
                    if (!snapshot.hasData){
                      return const Center(child: Text('Hold on....!'));
                    }
                    if(snapshot.connectionState == ConnectionState.waiting){

                      return const Center(
                        child: SizedBox(
                            height: 25, width: 25,
                            child: CircularProgressIndicator()),
                      );
                    }
                    else {
                      return GridView.builder(
                        padding: EdgeInsets.zero,
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 10, // Add horizontal spacing between grid items
                          mainAxisSpacing: 10, // Add vertical spacing between grid items
                        ),
                        itemCount: snapshot.data!.docs.length,
                        itemBuilder: (context, index) {
                          final item = snapshot.data!.docs[index];
                          final isComingSoon = item['status'] == 'coming_soon';
                          final color = items[currentImageIndex].color;
                          currentImageIndex = (currentImageIndex + 1) % items.length;
                          return GestureDetector(
                            onTap: isComingSoon
                                ? () {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('${item["name"]} is coming soon!'),
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  }
                                : () {
                                    EasyLoading.show(status: 'Please wait...!');
                                    appController.getSubCategoryRecord(id: item["id"]).then((_){
                                      Get.to(()=> SubCategoryView(name: item["name"]), transition: Transition.fadeIn);
                                      EasyLoading.dismiss();
                                    });
                                  },
                            child: Stack(
                              children: [
                                Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(20),
                                    color: isComingSoon ? Colors.grey.shade400 : color,
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Container(
                                        decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(10),
                                            color: Colors.white
                                        ),
                                        child: item["image"] == ""
                                            ? Image.asset('assets/images/no_image.png',
                                              width: width*0.15,
                                              height: height*0.065,)
                                            : ColorFiltered(
                                                colorFilter: isComingSoon
                                                    ? const ColorFilter.mode(Colors.grey, BlendMode.saturation)
                                                    : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
                                                child: Image.network(
                                                  item["image"],
                                                  width: width*0.15,
                                                  height: height*0.065,
                                                ),
                                              ),
                                      ),
                                      const SizedBox(height: 10),
                                      Center(
                                        child: Text(
                                          item["name"],
                                          style: GoogleFonts.inter(
                                            color: Colors.white,
                                            fontSize: width*0.045,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (isComingSoon)
                                  Positioned(
                                    top: 8,
                                    right: 8,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.shade700,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        'Coming Soon',
                                        style: GoogleFonts.inter(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );

                        },
                      );
                    }
                  }),
            ),
          ),
        ],
      ),
    );
  }
}

class DashboardItem {
  final Color color;

  DashboardItem({
    required this.color,
  });
}