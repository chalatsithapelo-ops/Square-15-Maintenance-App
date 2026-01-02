import 'dart:io';

import 'package:flutter/material.dart';

class AttachmentView extends StatelessWidget {
  final String imagePath;
  final bool isNetwork;
  final bool isLocal;
  const AttachmentView({super.key, required this.imagePath, this.isNetwork = true, this.isLocal = false});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFFc5a520),
          title: const Text('Attachment'),
        ),
        body: SizedBox(
          height: size.height,
          width: size.width,
          child: isNetwork
              ? InteractiveViewer(
                child: Image.network(
                  imagePath,
                  fit: BoxFit.contain,
                  width: size.width,
                  height: size.height,
                  loadingBuilder: (BuildContext context, Widget child, ImageChunkEvent? loadingProgress) {
                    if (loadingProgress == null) {
                      // Image is fully loaded
                      return child;
                    } else {
                      // Show a loading indicator while the image is loading
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              CircularProgressIndicator(
                                color: Theme.of(context).primaryColor,
                                value: loadingProgress.expectedTotalBytes != null
                                    ? loadingProgress.cumulativeBytesLoaded / (loadingProgress.expectedTotalBytes ?? 1)
                                    : null,
                              ),
                              const SizedBox(height: 20),
                              Text('${(loadingProgress.cumulativeBytesLoaded / (loadingProgress.expectedTotalBytes ?? 1) * 100).toStringAsFixed(2)} %',
                                  style: Theme.of(context).textTheme.labelSmall!.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).primaryColor,
                                    fontSize: 22,
                                  )),
                              const SizedBox(height: 5),
                              Text('Please wait, Image is loading...!', style: Theme.of(context).textTheme.labelSmall!.copyWith(
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).primaryColor,
                              )),
                            ],
                          ),
                          Positioned(
                            child: Opacity(
                                opacity: 0.1,
                                child: Image.asset('assets/images/no_image.png')),
                          ),
                        ],
                      );
                    }
                  },
                ),
              )
              : isLocal
              ? Image.file(File(imagePath), fit: BoxFit.cover)
              : InteractiveViewer(
              child: Image.asset(imagePath, fit: BoxFit.cover, width: size.width)),
        ),
      ),
    );
  }
}
