import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/model/category_model.dart';
import 'package:maintenanceapp/model/task_model.dart';
import 'package:maintenanceapp/screens/home/google_map/location_picker_screen.dart';
import 'package:maintenanceapp/services/firestore_services/firebase_services.dart';
import 'package:maintenanceapp/services/future_booking_service.dart';
import 'package:maintenanceapp/utils/primary_button.dart';
import 'package:uuid/uuid.dart';

class CreateFutureBookingScreen extends StatefulWidget {
  const CreateFutureBookingScreen({super.key});

  @override
  State<CreateFutureBookingScreen> createState() =>
      _CreateFutureBookingScreenState();
}

class _CreateFutureBookingScreenState extends State<CreateFutureBookingScreen> {
  final AppController appController = Get.find();

  DateTime? selectedDate;
  TimeOfDay? selectedTime;
  String? selectedCategoryId;
  String? selectedCategoryName;
  List<String> selectedTaskIds = [];
  Map<String, String> taskNames = {};
  Map<String, double> taskCosts = {};
  List<File> workImages = [];
  bool isRFQ = false;
  String rfqReason = '';

  final TextEditingController _taskSearchController = TextEditingController();
  String _taskSearchQuery = '';
  String _taskFilter = 'all'; // all | fixed | rfq
  List<String> _categoryScopeIds = [];

  TextEditingController descriptionController = TextEditingController();
  TextEditingController addressController = TextEditingController();
  bool isLoading = false;
  bool serviceOnCurrentLocation = true;
  String pickedLat = "";
  String pickedLng = "";
  String materialsResponsibility = 'client';
  final ImagePicker _imagePicker = ImagePicker();

  Future<void> _loadCategoryScopeIds(String categoryId) async {
    try {
      final subSnap = await FirebaseService.categoryRef
          .where('status', isEqualTo: 'publish')
          .where('parent_id', isEqualTo: categoryId)
          .get();

      final ids = <String>{categoryId};
      for (final doc in subSnap.docs) {
        final data = (doc.data() as Map<String, dynamic>?) ??
            <String, dynamic>{};
        final id = (data['id'] ?? doc.id).toString();
        if (id.isNotEmpty) ids.add(id);
      }

      if (!mounted) return;
      setState(() {
        _categoryScopeIds = ids.toList();
      });
    } catch (e) {
      // Fallback to just the selected category.
      if (!mounted) return;
      setState(() {
        _categoryScopeIds = [categoryId];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Schedule Future Booking',
                style: GoogleFonts.roboto(color: Colors.white, fontSize: 18)),
            Text('v2.0 - Dec 20, 2025',
                style: GoogleFonts.roboto(color: Colors.white70, fontSize: 10)),
          ],
        ),
        backgroundColor: const Color(0xFFc5a520),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // RFQ Status Banner
            if (isRFQ) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.orange, width: 2),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.request_quote,
                        color: Colors.orange, size: 30),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'RFQ Mode Active',
                            style: GoogleFonts.roboto(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.orange.shade900,
                            ),
                          ),
                          Text(
                            rfqReason == 'no_pricing'
                                ? 'Selected service requires quotation'
                                : rfqReason == 'big_job'
                                    ? 'Big job - Admin will provide quote'
                                    : rfqReason == 'client_requested'
                                        ? 'Quotation requested - Admin will provide quote'
                                        : 'Request for Quotation',
                            style: GoogleFonts.roboto(
                              fontSize: 12,
                              color: Colors.orange.shade800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],

            // Booking Type
            Text('Booking Type',
                style: GoogleFonts.roboto(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              'Choose Order if you want a fixed-priced service, or RFQ if you need a quotation.',
              style: GoogleFonts.roboto(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            RadioListTile<String>(
              value: 'order',
              groupValue: isRFQ ? 'rfq' : 'order',
              activeColor: const Color(0xFFc5a520),
              title: Text('Order (fixed-priced service)',
                  style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  isRFQ = false;
                  rfqReason = '';
                });
              },
            ),
            RadioListTile<String>(
              value: 'rfq',
              groupValue: isRFQ ? 'rfq' : 'order',
              activeColor: Colors.orange,
              title: Text('RFQ (Request for Quotation)',
                  style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
              subtitle: Text(
                'Use this for big jobs or when pricing is not listed. Admin will provide a quote.',
                style: GoogleFonts.roboto(fontSize: 12, color: Colors.grey),
              ),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  isRFQ = true;
                  rfqReason =
                      rfqReason.isNotEmpty ? rfqReason : 'client_requested';
                  // RFQ can be created without selecting a listed service
                  selectedTaskIds.clear();
                  taskNames.clear();
                  taskCosts.clear();
                });
              },
            ),
            if (isRFQ) ...[
              const SizedBox(height: 8),
              Text('RFQ Reason',
                  style: GoogleFonts.roboto(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              RadioListTile<String>(
                value: 'client_requested',
                groupValue: rfqReason.isEmpty ? 'client_requested' : rfqReason,
                activeColor: Colors.orange,
                title: Text('I need a quotation',
                    style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    rfqReason = value;
                  });
                },
              ),
              RadioListTile<String>(
                value: 'big_job',
                groupValue: rfqReason.isEmpty ? 'client_requested' : rfqReason,
                activeColor: Colors.orange,
                title: Text('This is a big job',
                    style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
                subtitle: Text('Admin will review and provide a custom quote',
                    style:
                        GoogleFonts.roboto(fontSize: 12, color: Colors.grey)),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    rfqReason = value;
                  });
                },
              ),
              const SizedBox(height: 12),
            ],

            const SizedBox(height: 20),

            // Date Selection
            Text('Select Date',
                style: GoogleFonts.roboto(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => _selectDate(context),
              child: Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today, color: Color(0xFFc5a520)),
                    const SizedBox(width: 10),
                    Text(
                      selectedDate == null
                          ? 'Choose a date'
                          : DateFormat('EEEE, MMM dd, yyyy')
                              .format(selectedDate!),
                      style: GoogleFonts.roboto(fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Time Selection
            Text('Select Time',
                style: GoogleFonts.roboto(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => _selectTime(context),
              child: Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.access_time, color: Color(0xFFc5a520)),
                    const SizedBox(width: 10),
                    Text(
                      selectedTime == null
                          ? 'Choose a time'
                          : selectedTime!.format(context),
                      style: GoogleFonts.roboto(fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Category Selection
            Text('Select Service Category',
                style: GoogleFonts.roboto(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseService.categoryRef
                  .where('status', isEqualTo: 'publish')
                  .where('parent_id', isEqualTo: '')
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                List<CategoryModel> categories = snapshot.data!.docs
                    .map((doc) => CategoryModel.fromDocument(
                        doc.data() as Map<String, dynamic>))
                    .toList();

                return DropdownButtonFormField<String>(
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 15, vertical: 15),
                  ),
                  hint: Text('Select a category', style: GoogleFonts.roboto()),
                  value: selectedCategoryId,
                  items: categories.map((category) {
                    return DropdownMenuItem(
                      value: category.id,
                      child: Text(category.name),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() {
                      selectedCategoryId = value;
                      selectedCategoryName =
                          categories.firstWhere((c) => c.id == value).name;
                      selectedTaskIds.clear();
                      taskNames.clear();
                      taskCosts.clear();
                      _taskSearchQuery = '';
                      _taskSearchController.clear();
                      _taskFilter = 'all';
                      _categoryScopeIds = value == null ? [] : [value];
                    });
                    if (value != null) {
                      _loadCategoryScopeIds(value);
                    }
                  },
                );
              },
            ),
            const SizedBox(height: 20),

            // Task/Service Selection (Orders only)
            if (selectedCategoryId != null && !isRFQ) ...[
              Text('Select Services',
                  style: GoogleFonts.roboto(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),

              TextField(
                controller: _taskSearchController,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search services (A-Z)',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.all(12),
                ),
                onChanged: (v) {
                  setState(() {
                    _taskSearchQuery = v.trim().toLowerCase();
                  });
                },
              ),
              const SizedBox(height: 10),

              DropdownButtonFormField<String>(
                value: _taskFilter,
                decoration: InputDecoration(
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('All services')),
                  DropdownMenuItem(
                      value: 'fixed', child: Text('Fixed price only')),
                  DropdownMenuItem(
                      value: 'rfq', child: Text('RFQ required only')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _taskFilter = v;
                  });
                },
              ),
              const SizedBox(height: 10),

              StreamBuilder<QuerySnapshot>(
                stream: FirebaseService.taskRef
                    .where('status', isEqualTo: 'publish')
                    .snapshots(), // Get ALL published tasks, filter in code
                builder: (context, taskSnapshot) {
                  if (!taskSnapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  List<TaskModel> allTasks = taskSnapshot.data!.docs
                      .map((doc) => TaskModel.fromDocument(
                          doc.data() as Map<String, dynamic>))
                      .toList();

                  final scope = _categoryScopeIds.isNotEmpty
                      ? _categoryScopeIds.toSet()
                      : {selectedCategoryId!};

                  List<TaskModel> tasks = allTasks
                      .where((t) => t.categoryId != null &&
                          t.categoryId!.isNotEmpty &&
                          scope.contains(t.categoryId))
                      .toList();

                  // Search
                  if (_taskSearchQuery.isNotEmpty) {
                    tasks = tasks
                        .where((t) =>
                            (t.name ?? '').toLowerCase().contains(_taskSearchQuery))
                        .toList();
                  }

                  // Filter
                  bool hasPricing(TaskModel t) {
                    return t.cost != null &&
                        t.cost!.isNotEmpty &&
                        t.cost != '0';
                  }

                  if (_taskFilter == 'fixed') {
                    tasks = tasks.where(hasPricing).toList();
                  } else if (_taskFilter == 'rfq') {
                    tasks = tasks.where((t) => !hasPricing(t)).toList();
                  }

                  // Alphabetical
                  tasks.sort((a, b) =>
                      (a.name ?? '').toLowerCase().compareTo((b.name ?? '').toLowerCase()));

                  if (tasks.isEmpty) {
                    return Column(
                      children: [
                        const Icon(Icons.info_outline,
                            size: 48, color: Colors.grey),
                        const SizedBox(height: 10),
                        Text('No services found for this category',
                            style: GoogleFonts.roboto(color: Colors.grey)),
                        const SizedBox(height: 5),
                        Text(
                          'Try a different search/filter, or request a quote below.',
                          style: GoogleFonts.roboto(
                              fontSize: 12, color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    );
                  }

                  return Column(
                    children: [
                      ...tasks.map((task) {
                        bool isSelected = selectedTaskIds.contains(task.id);
                        bool priced = hasPricing(task);

                        return CheckboxListTile(
                          title: Text(task.name ?? 'Unknown',
                              style: GoogleFonts.roboto()),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (priced)
                                Text('Cost: R${task.cost}',
                                    style: GoogleFonts.roboto(
                                        fontSize: 12, color: Colors.green))
                              else
                                Text('No fixed pricing - RFQ required',
                                    style: GoogleFonts.roboto(
                                        fontSize: 12,
                                        color: Colors.orange,
                                        fontWeight: FontWeight.bold)),
                            ],
                          ),
                          value: isSelected,
                          activeColor: const Color(0xFFc5a520),
                          onChanged: (bool? value) {
                            setState(() {
                              if (value == true) {
                                selectedTaskIds.add(task.id!);
                                taskNames[task.id!] = task.name!;
                                taskCosts[task.id!] =
                                    double.tryParse(task.cost ?? '0') ?? 0;

                                // Check if any selected task requires RFQ
                                if (!priced) {
                                  isRFQ = true;
                                  rfqReason = 'no_pricing';
                                }
                              } else {
                                selectedTaskIds.remove(task.id);
                                taskNames.remove(task.id);
                                taskCosts.remove(task.id);

                                // Recheck if RFQ is still needed
                                isRFQ = selectedTaskIds.any((id) {
                                  var taskCost = taskCosts[id] ?? 0;
                                  return taskCost == 0;
                                });
                              }
                            });
                          },
                        );
                      }),
                      const SizedBox(height: 10),
                      // Option to request RFQ for big jobs
                      CheckboxListTile(
                        title: Text('This is a big job - Request quotation',
                            style: GoogleFonts.roboto(
                                fontWeight: FontWeight.w600)),
                        subtitle: Text(
                            'Admin will review and provide a custom quote',
                            style: GoogleFonts.roboto(
                                fontSize: 12, color: Colors.grey)),
                        value: isRFQ && rfqReason == 'big_job',
                        activeColor: Colors.orange,
                        onChanged: selectedTaskIds.isEmpty
                            ? null
                            : (bool? value) {
                                setState(() {
                                  if (value == true) {
                                    isRFQ = true;
                                    rfqReason = 'big_job';
                                  } else {
                                    // Check if still needs RFQ due to no pricing
                                    bool needsRFQ = selectedTaskIds.any((id) {
                                      var taskCost = taskCosts[id] ?? 0;
                                      return taskCost == 0;
                                    });
                                    if (!needsRFQ) {
                                      isRFQ = false;
                                      rfqReason = '';
                                    }
                                  }
                                });
                              },
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      "Can't find what you are looking for?",
                      style:
                          GoogleFonts.roboto(fontSize: 13, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        isRFQ = true;
                        rfqReason = 'client_requested';
                        selectedTaskIds.clear();
                        taskNames.clear();
                        taskCosts.clear();
                      });
                    },
                    child: Text(
                      'Request a quote',
                      style: GoogleFonts.roboto(
                        fontWeight: FontWeight.bold,
                        color: Colors.orange.shade800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
            ],

            // RFQ note (no service selection required)
            if (selectedCategoryId != null && isRFQ) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Text(
                  'RFQ selected: you do not need to pick a listed service. Provide details below and admin will quote based on your category and description.',
                  style: GoogleFonts.roboto(
                      fontSize: 12, color: Colors.orange.shade900),
                ),
              ),
              const SizedBox(height: 20),
            ],

            // Description
            Text('Detailed description of what needs to be fixed.',
                style: GoogleFonts.roboto(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            TextField(
              controller: descriptionController,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'Describe the issue in detail (what is broken, where, and any symptoms)',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.all(15),
              ),
            ),
            const SizedBox(height: 20),

            // Image Upload Section
            Text('Upload Work Images',
                style: GoogleFonts.roboto(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 5),
            Text(
              'Show us the current state of the work',
                style: GoogleFonts.roboto(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  if (workImages.isEmpty)
                    Text('No images added yet',
                        style: GoogleFonts.roboto(color: Colors.grey))
                  else
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: workImages.asMap().entries.map((entry) {
                        int index = entry.key;
                        File image = entry.value;
                        return Stack(
                          children: [
                            Container(
                              width: 100,
                              height: 100,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                image: DecorationImage(
                                  image: FileImage(image),
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                            Positioned(
                              right: 0,
                              top: 0,
                              child: GestureDetector(
                                onTap: () {
                                  setState(() {
                                    workImages.removeAt(index);
                                  });
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: const BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.close,
                                      color: Colors.white, size: 16),
                                ),
                              ),
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () => _pickImage(ImageSource.camera),
                        icon: const Icon(Icons.camera_alt),
                        label: Text('Camera', style: GoogleFonts.roboto()),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFc5a520),
                          foregroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton.icon(
                        onPressed: () => _pickImage(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library),
                        label: Text('Gallery', style: GoogleFonts.roboto()),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFc5a520),
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Materials Responsibility
            Text('Materials',
                style: GoogleFonts.roboto(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              'Who will buy the materials?',
              style: GoogleFonts.roboto(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            RadioListTile<String>(
              value: 'client',
              groupValue: materialsResponsibility,
              activeColor: const Color(0xFFc5a520),
              title: Text('I will buy my own materials',
                  style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  materialsResponsibility = value;
                });
              },
            ),
            RadioListTile<String>(
              value: 'artisan',
              groupValue: materialsResponsibility,
              activeColor: const Color(0xFFc5a520),
              title: Text('Artisan must buy materials and come with everything',
                  style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  materialsResponsibility = value;
                });
              },
            ),
            const SizedBox(height: 20),

            // Service Location
            Text('Service Location',
                style: GoogleFonts.roboto(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text('Do you want the service at your current location?',
                style: GoogleFonts.roboto(fontSize: 14)),
            Row(
              children: [
                Row(
                  children: [
                    Text('Yes', style: GoogleFonts.roboto(fontSize: 14)),
                    Checkbox(
                      activeColor: const Color(0xFFc5a520),
                      value: serviceOnCurrentLocation,
                      onChanged: (value) {
                        setState(() {
                          serviceOnCurrentLocation = true;
                          addressController.clear();
                          pickedLat = "";
                          pickedLng = "";
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(width: 20),
                Row(
                  children: [
                    Text('No', style: GoogleFonts.roboto(fontSize: 14)),
                    Checkbox(
                      activeColor: const Color(0xFFc5a520),
                      value: !serviceOnCurrentLocation,
                      onChanged: (value) {
                        setState(() {
                          serviceOnCurrentLocation = false;
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),

            if (!serviceOnCurrentLocation) ...[
              const SizedBox(height: 10),
              Text('Add Location',
                  style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      readOnly: true,
                      controller: addressController,
                      decoration: InputDecoration(
                        labelText: 'Please pick your location',
                        labelStyle: GoogleFonts.roboto(
                            fontSize: 12, color: const Color(0xffACADB9)),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                        filled: true,
                        fillColor: Colors.white,
                        prefixIcon: const Icon(Icons.location_on,
                            color: Color(0xffACADB9)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 15, vertical: 15),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () async {
                      final result = await Get.to(() => LocationPickerScreen(
                            initialLat: pickedLat.isEmpty
                                ? double.parse(
                                    appController.userLat.value.isEmpty
                                        ? "0.0"
                                        : appController.userLat.value)
                                : double.parse(pickedLat),
                            initialLng: pickedLng.isEmpty
                                ? double.parse(
                                    appController.userLng.value.isEmpty
                                        ? "0.0"
                                        : appController.userLng.value)
                                : double.parse(pickedLng),
                            initialAddress: "",
                          ));

                      if (result != null) {
                        setState(() {
                          pickedLat = result['latitude'].toString();
                          pickedLng = result['longitude'].toString();
                          addressController.text = result['address'].toString();
                        });
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(15),
                      decoration: BoxDecoration(
                        color: const Color(0xFFc5a520).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFc5a520)),
                      ),
                      child: const Icon(Icons.add_location,
                          color: Color(0xFFc5a520)),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 20),

            // Total Cost
            if (taskCosts.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFc5a520)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Total Estimated Cost:',
                        style: GoogleFonts.roboto(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    Text(
                      'R${taskCosts.values.fold(0.0, (sum, cost) => sum + cost).toStringAsFixed(2)}',
                      style: GoogleFonts.roboto(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFFc5a520)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
            ],

            // Submit Button
            isLoading
                ? const Center(child: CircularProgressIndicator())
                : SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      onPressed: _createBooking,
                      color: isRFQ ? Colors.orange : const Color(0xFFc5a520),
                      title: isRFQ ? 'Submit RFQ Request' : 'Schedule Booking',
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: source,
        imageQuality: 70,
        maxWidth: 1024,
        maxHeight: 1024,
      );

      if (pickedFile != null) {
        setState(() {
          workImages.add(File(pickedFile.path));
        });
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
      Get.snackbar('Error', 'Failed to pick image',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<List<String>> _uploadImages() async {
    List<String> imageUrls = [];

    for (File image in workImages) {
      try {
        String fileName =
          'booking_images/${DateTime.now().millisecondsSinceEpoch}_${Uuid().v4()}.jpg';
        Reference storageRef = FirebaseStorage.instance.ref().child(fileName);

        UploadTask uploadTask = storageRef.putFile(image);
        TaskSnapshot snapshot = await uploadTask;
        String downloadUrl = await snapshot.ref.getDownloadURL();

        imageUrls.add(downloadUrl);
      } catch (e) {
        debugPrint('Error uploading image: $e');
      }
    }

    return imageUrls;
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now().add(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 90)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFFc5a520),
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && picked != selectedDate) {
      setState(() {
        selectedDate = picked;
      });
    }
  }

  Future<void> _selectTime(BuildContext context) async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFFc5a520),
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && picked != selectedTime) {
      setState(() {
        selectedTime = picked;
      });
    }
  }

  Future<void> _createBooking() async {
    // Validation
    if (selectedDate == null) {
      Get.snackbar('Error', 'Please select a date',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }
    if (selectedTime == null) {
      Get.snackbar('Error', 'Please select a time',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }
    if (selectedCategoryId == null) {
      Get.snackbar('Error', 'Please select a service category',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }
    if (!isRFQ && selectedTaskIds.isEmpty) {
      Get.snackbar('Error', 'Please select at least one service',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }
    if (isRFQ && descriptionController.text.trim().isEmpty) {
      Get.snackbar('Error', 'Please describe what you need a quote for',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }
    if (!serviceOnCurrentLocation && addressController.text.isEmpty) {
      Get.snackbar('Error', 'Please select a location address',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }
    if (!serviceOnCurrentLocation &&
        (pickedLat.trim().isEmpty || pickedLng.trim().isEmpty)) {
      Get.snackbar('Error', 'Please pick the service location on the map',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }
    if (workImages.isEmpty) {
      Get.snackbar('Error', 'Please upload at least one work image',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }

    setState(() => isLoading = true);

    try {
      // Ensure we have a fresh device location if the service is on the current location.
      if (serviceOnCurrentLocation &&
          (appController.userLat.value.trim().isEmpty ||
              appController.userLng.value.trim().isEmpty)) {
        try {
          await appController.getCurrentPosition(context);
        } catch (_) {}
      }
      if (serviceOnCurrentLocation &&
          (appController.userLat.value.trim().isEmpty ||
              appController.userLng.value.trim().isEmpty)) {
        Get.snackbar('Error', 'Please enable location to dispatch an artisan',
            backgroundColor: Colors.red, colorText: Colors.white);
        return;
      }

      // Upload images first
      final List<String> imageUrls = await _uploadImages();

      // Format scheduled datetime
      String scheduledDate = DateFormat('yyyy-MM-dd').format(selectedDate!);
      String scheduledTime =
          '${selectedTime!.hour.toString().padLeft(2, '0')}:${selectedTime!.minute.toString().padLeft(2, '0')}:00';

      // Calculate total cost (orders only; RFQs are quoted later)
      double totalCost = taskCosts.values.fold(0.0, (sum, cost) => sum + cost);

      final result = await FutureBookingService.createBookingAndNotify(
        userId: appController.userId.value,
        jobIds: isRFQ ? [] : selectedTaskIds,
        taskNamesById: isRFQ ? {} : taskNames,
        taskCostsById: isRFQ ? {} : taskCosts,
        scheduledDate: scheduledDate,
        scheduledTime: scheduledTime,
        serviceOnCurrentLocation: serviceOnCurrentLocation,
        userLat: appController.userLat.value,
        userLng: appController.userLng.value,
        providedAddress: addressController.text,
        otherLat: pickedLat,
        otherLng: pickedLng,
        workImageUrls: imageUrls,
        description: descriptionController.text,
        categoryId: selectedCategoryId,
        categoryName: selectedCategoryName,
        materialsResponsibility: materialsResponsibility,
        isRFQRequested: isRFQ,
        rfqReason: rfqReason.isNotEmpty
            ? rfqReason
            : (isRFQ ? 'client_requested' : ''),
        createdBy: 'manual',
      );

      final bool createdAsRFQ = (result['isRFQ'] as bool?) ?? false;
      final assignedArtisanId = (result['assignedArtisanId'] ?? '').toString();

      if (createdAsRFQ) {
        Get.snackbar(
          'RFQ Submitted',
          'Your request has been sent to admin for review. You will be contacted shortly.',
          backgroundColor: Colors.green,
          colorText: Colors.white,
          duration: const Duration(seconds: 5),
        );
      } else {
        Get.snackbar(
          'Success',
          assignedArtisanId.trim().isNotEmpty
              ? 'Your booking has been scheduled! The nearest artisan has been notified and will confirm shortly.'
              : 'Your booking has been scheduled! Dispatch is in progress and an artisan will be assigned shortly.',
          backgroundColor: Colors.green,
          colorText: Colors.white,
          duration: const Duration(seconds: 4),
        );
      }

      Navigator.pop(context);
    } catch (e) {
      debugPrint('Error creating booking: $e');
      Get.snackbar('Error', 'Failed to create booking: ${e.toString()}',
          backgroundColor: Colors.red, colorText: Colors.white);
    } finally {
      setState(() => isLoading = false);
    }
  }

  @override
  void dispose() {
    descriptionController.dispose();
    addressController.dispose();
    _taskSearchController.dispose();
    super.dispose();
  }
}
