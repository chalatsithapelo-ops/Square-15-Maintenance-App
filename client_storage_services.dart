import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:uuid/uuid.dart';

class StorageServices {
  static String _sanitizeBucket(String raw) {
    var b = raw.toString().trim();
    if (b.startsWith('gs://')) b = b.substring(5);
    if (b.endsWith('/')) b = b.substring(0, b.length - 1);
    return b;
  }

  /// Returns a list of bucket names to try (default + alternate naming).
  static List<String> _bucketCandidates(String primary) {
    final out = <String>[];
    void add(String b) {
      final s = _sanitizeBucket(b);
      if (s.isEmpty) return;
      if (!out.contains(s)) out.add(s);
    }

    add(primary);

    for (final b in List<String>.from(out)) {
      if (b.endsWith('.firebasestorage.app')) {
        add(b.replaceAll('.firebasestorage.app', '.appspot.com'));
      }
      if (b.endsWith('.appspot.com')) {
        add(b.replaceAll('.appspot.com', '.firebasestorage.app'));
      }
    }

    return out;
  }

  static Future<String> uploadImageToDB(
    String? selectedImagePath,
  ) async {
    FirebaseStorage fs = FirebaseStorage.instance;
    Reference ref = fs.ref().child(DateTime.now().millisecondsSinceEpoch.toString());
    await ref.putFile(File(selectedImagePath!));
    String url = await ref.getDownloadURL();
    return url;
  }

  /// Try uploading with a given [FirebaseStorage] instance (bucket).
  /// Returns the download URL on success, or throws with details on failure.
  static Future<String?> _tryUploadWithStorage({
    required FirebaseStorage storage,
    required String objectPath,
    required File imageFile,
  }) async {
    final ref = storage.ref().child(objectPath);
    print('[_tryUpload] bucket=${ref.bucket} path=$objectPath');

    // --- Attempt 1: plain putFile (no custom metadata) ---
    String? putError;
    bool uploaded = false;
    try {
      final task = ref.putFile(imageFile);
      await task;
      uploaded = true;
      print('[_tryUpload] putFile succeeded on bucket=${ref.bucket}');
    } catch (e) {
      putError = e.toString();
      print('[_tryUpload] putFile plain FAILED on bucket=${ref.bucket}: $e');
      // --- Attempt 2: putData (bytes) as fallback ---
      try {
        final bytes = await imageFile.readAsBytes();
        final task = ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
        await task;
        uploaded = true;
        print('[_tryUpload] putData succeeded on bucket=${ref.bucket}');
      } catch (e2) {
        putError = e2.toString();
        print('[_tryUpload] putData FAILED on bucket=${ref.bucket}: $e2');
      }
    }

    if (!uploaded) {
      print('[_tryUpload] All upload attempts failed on bucket=${ref.bucket}: $putError');
      throw Exception('Storage upload failed on ${ref.bucket}: $putError');
    }

    // Upload succeeded – try to get the URL.
    // 1) Prefer official getDownloadURL.
    try {
      final url = await ref.getDownloadURL();
      if (url.trim().isNotEmpty) {
        print('[_tryUpload] getDownloadURL OK: $url');
        return url;
      }
    } catch (e) {
      print('[_tryUpload] getDownloadURL failed: $e');
    }

    // 2) Fallback: set download token metadata and build token URL.
    final token = const Uuid().v4();
    try {
      await ref.updateMetadata(SettableMetadata(
        customMetadata: {'firebaseStorageDownloadTokens': token},
      ));
    } catch (_) {
      // metadata update is best-effort
    }
    final bucket = _sanitizeBucket(ref.bucket);
    final encodedPath = Uri.encodeComponent(objectPath);
    final url = 'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$encodedPath?alt=media&token=$token';
    print('[_tryUpload] Constructed token URL: $url');
    return url;
  }


  static Future<String> uploadImageToFirebase({required String path, required File imageFile, required String id}) async {
    final String objectPath = '$path/$id.jpg';
    final fileSize = await imageFile.length();
    print('[uploadImageToFirebase] path=$objectPath size=$fileSize bytes');

    final storage = FirebaseStorage.instance;
    final ref = storage.ref().child(objectPath);
    print('[uploadImageToFirebase] bucket=${ref.bucket}');

    try {
      // Upload the file
      await ref.putFile(imageFile);
      print('[uploadImageToFirebase] putFile succeeded');
    } catch (e) {
      print('[uploadImageToFirebase] putFile failed: $e — trying putData');
      // Fallback: read bytes and upload as data
      try {
        final bytes = await imageFile.readAsBytes();
        await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
        print('[uploadImageToFirebase] putData succeeded');
      } catch (e2) {
        print('[uploadImageToFirebase] putData also failed: $e2');
        throw Exception('Image upload failed: $e2');
      }
    }

    // Get the download URL
    try {
      final url = await ref.getDownloadURL();
      if (url.trim().isNotEmpty) {
        print('[uploadImageToFirebase] getDownloadURL OK: $url');
        return url;
      }
    } catch (e) {
      print('[uploadImageToFirebase] getDownloadURL failed: $e — building token URL');
    }

    // Fallback: construct a token-based URL
    final token = const Uuid().v4();
    try {
      await ref.updateMetadata(SettableMetadata(
        customMetadata: {'firebaseStorageDownloadTokens': token},
      ));
    } catch (_) {
      // metadata update is best-effort
    }
    final bucket = _sanitizeBucket(ref.bucket);
    final encodedPath = Uri.encodeComponent(objectPath);
    final url = 'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$encodedPath?alt=media&token=$token';
    print('[uploadImageToFirebase] Constructed token URL: $url');
    return url;
  }

  static Future<void> deleteImage({required String path, required String id}) async {
    FirebaseStorage.instance.ref().child('$path/$id.jpg').delete();
  }
}
