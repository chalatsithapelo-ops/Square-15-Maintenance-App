import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:maintenanceapp/utils/primary_button.dart';
import 'package:uuid/uuid.dart';

class AiPhotoUploadScreen extends StatefulWidget {
  final String categoryName;
  final String problemDescription;
  final String additionalNotes;
  final bool serviceOnCurrentLocation;
  final String serviceAddress;
  final int minPhotos;

  const AiPhotoUploadScreen({
    super.key,
    required this.categoryName,
    required this.problemDescription,
    required this.additionalNotes,
    required this.serviceOnCurrentLocation,
    required this.serviceAddress,
    this.minPhotos = 3,
  });

  @override
  State<AiPhotoUploadScreen> createState() => _AiPhotoUploadScreenState();
}

class _AiPhotoUploadScreenState extends State<AiPhotoUploadScreen> {
  final ImagePicker _imagePicker = ImagePicker();

  final List<File> _images = [];
  bool _uploading = false;

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
          _images.add(File(pickedFile.path));
        });
      }
    } catch (e) {
      Get.snackbar('Error', 'Failed to pick image',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<List<String>> _uploadImages() async {
    final urls = <String>[];

    for (final image in _images) {
      try {
        final fileName =
            'booking_images/${DateTime.now().millisecondsSinceEpoch}_${const Uuid().v4()}.jpg';
        final storageRef = FirebaseStorage.instance.ref().child(fileName);

        final uploadTask = storageRef.putFile(image);
        final snapshot = await uploadTask;
        final downloadUrl = await snapshot.ref.getDownloadURL();

        urls.add(downloadUrl);
      } catch (_) {
        // Keep going; we'll validate count after.
      }
    }

    return urls;
  }

  Future<void> _done() async {
    if (_uploading) return;

    if (_images.length < widget.minPhotos) {
      Get.snackbar(
        'Photos required',
        'Please upload at least ${widget.minPhotos} photos.',
        backgroundColor: Colors.orange,
        colorText: Colors.white,
      );
      return;
    }

    setState(() {
      _uploading = true;
    });

    try {
      final urls = await _uploadImages();
      if (urls.length < widget.minPhotos) {
        Get.snackbar(
          'Upload failed',
          'Some images failed to upload. Please try again.',
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
        return;
      }

      if (!mounted) return;
      Navigator.of(context).pop(urls);
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Upload Photos'),
        backgroundColor: Colors.orange,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.categoryName,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              widget.problemDescription.trim().isNotEmpty
                  ? widget.problemDescription.trim()
                  : 'Please upload clear photos of the issue.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            if (widget.additionalNotes.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                widget.additionalNotes.trim(),
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              widget.serviceOnCurrentLocation
                  ? 'Service location: current location'
                  : 'Service location: ${widget.serviceAddress.trim().isEmpty ? 'provided address' : widget.serviceAddress.trim()}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 20),
            Text(
              'Upload Photos (min ${widget.minPhotos})',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  if (_images.isEmpty)
                    Column(
                      children: [
                        Icon(Icons.add_photo_alternate,
                            size: 60, color: Colors.grey.shade400),
                        const SizedBox(height: 10),
                        Text('No images added yet',
                            style: TextStyle(color: Colors.grey.shade700)),
                        const SizedBox(height: 5),
                        Text(
                          'Please add at least ${widget.minPhotos} clear photos',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.orange,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    )
                  else
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: _images.asMap().entries.map((entry) {
                        final index = entry.key;
                        final image = entry.value;
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
                                onTap: _uploading
                                    ? null
                                    : () {
                                        setState(() {
                                          _images.removeAt(index);
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
                  const SizedBox(height: 15),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _uploading
                            ? null
                            : () => _pickImage(ImageSource.camera),
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Camera'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton.icon(
                        onPressed: _uploading
                            ? null
                            : () => _pickImage(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library),
                        label: const Text('Gallery'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            PrimaryButton(
              title: _uploading ? 'Uploading...' : 'Done',
              onPressed: _uploading ? null : _done,
            ),
          ],
        ),
      ),
    );
  }
}
