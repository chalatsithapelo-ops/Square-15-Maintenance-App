
import 'dart:developer';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'package:maintenanceapp/utils/splash_timer.dart';

class GoogleMapView extends StatefulWidget {
  final String id;
  final String name;
  final TaskManagementModel? taskRecord;
  const GoogleMapView({super.key, required this.id, this.taskRecord, required this.name});

  @override
  State<GoogleMapView> createState() => _GoogleMapViewState();
}

class _GoogleMapViewState extends State<GoogleMapView> {

  Position? currentPosition;
  LatLng? otherUserPosition;
  late GoogleMapController mapController;
  final double _currentZoom = 15.0;
  final Set<Marker> _markers = {};
  GeolocatorPlatform geoLocator = GeolocatorPlatform.instance;


  @override
  void initState() {

    super.initState();
    getCurrentLocation();
    getSecondUserLocation();
  }

  @override
  void dispose() {

    if(currentPosition == null){
      appController.saveLastLocationOfCurrentUser(
          lat: currentPosition!.latitude.toString(),
          lng: currentPosition!.longitude.toString());
    }

    super.dispose();

  }


  getSecondUserLocation() async {
    log("idr aya.....");
    log("other user id ${widget.id}");
    final ref = FirebaseDatabase.instance.ref();
    ref.child('locations/${widget.id}').onValue.listen((event) async {
      log("Listening value........!");
      if (event.snapshot.exists) {
        final data = event.snapshot.value as Map<dynamic, dynamic>;
        debugPrint('other user id ${event.snapshot.key}');
        debugPrint('other user $data');
        var latitude = data["location"]["lat"].toString();
        var longitude = data["location"]["lng"].toString();
        double lat = double.parse(latitude);
        double lng = double.parse(longitude);
        otherUserPosition = LatLng(lat, lng);
        debugPrint('other user $otherUserPosition');
        await createMarker();

      }
      else {
        DatabaseReference ref = FirebaseDatabase.instance.ref("locations");
        log('No data available.');
        var isProvider = await appController.isServiceProvider(appController.userId.value);
        log("isProvider $isProvider");
        if(!isProvider){
          if(widget.taskRecord != null){
            log("idr");
            if(widget.taskRecord!.isServiceOnCurrentLocation != ""){
              if(widget.taskRecord!.isServiceOnCurrentLocation == "0"){
                if(widget.taskRecord!.otherLng != null && widget.taskRecord!.otherLat != null){
                  await ref.update({
                    "${widget.taskRecord!.serviceProviderId}": {
                      "name": widget.name,
                      "location": {"lat": widget.taskRecord!.otherLat, "lng": widget.taskRecord!.otherLng}
                    },
                  });
                  print("Saved Locations");
                }
              }
              else{
                DocumentSnapshot<Map<String, dynamic>> providerData =  await appController.serviceProviderRef.doc(widget.taskRecord!.serviceProviderId).get();
                if(widget.taskRecord!.otherLng != null && widget.taskRecord!.otherLat != null){
                  await ref.update({
                    "${widget.taskRecord!.serviceProviderId}": {
                      "name": widget.name,
                      "location": {"lat": providerData["lat"], "lng": providerData["lng"]}
                    },
                  });
                }
              }
              print("Saved Locations ${widget.taskRecord!.isServiceOnCurrentLocation}");
              getSecondUserLocation();
            }
          }
        }
        else{
          DocumentSnapshot<Map<String, dynamic>> userData =  await appController.userRef.doc(widget.taskRecord!.userId).get();
          if(widget.taskRecord!.otherLng != null && widget.taskRecord!.otherLat != null){
            await ref.update({
              "${widget.taskRecord!.userId}": {
                "name": userData["name"],
                "location": {"lat": userData["lat"], "lng": userData["lng"]}
              },
            });
            debugPrint("save location for ${userData["name"]}");
          }
          getSecondUserLocation();
        }
      }
    }).onError((e){
      log("getSecondUserLocation $e");
    });
    setState(() {});
  }

  void _onMapCreated(GoogleMapController controller) {
    mapController = controller;

  }
  Future<void> getCurrentLocation() async {
    final hasPermission = await _handleLocationPermission(context);
    if (!hasPermission) return;
    geoLocator.getPositionStream().listen((Position newPosition) async {
      currentPosition = newPosition;
      if(mounted){
        if(currentPosition != null){
          debugPrint("My Position ${currentPosition!.latitude}, ${currentPosition!.longitude}");

          ///updating current position using FireStore Database
          // appController.updateMyCurrentPositionToFirebase(
          //     lat: currentPosition!.latitude.toString(),
          //     lng: currentPosition!.longitude.toString());

          ///updating current position using Firebase RealTime Database
          appController.updateMyCurrentPositionToFirebaseRealTime(
              lat: currentPosition!.latitude.toString(),
              lng: currentPosition!.longitude.toString());

          // otherUserPosition = await appController.getOtherUserLocation(id: widget.id);
          createMarker();
          setState(() {});
        }
      }
    });

    if(otherUserPosition != null){
      debugPrint("other user ${otherUserPosition!.latitude}, ${otherUserPosition!.longitude}");
    }

  }

  Future<bool> _handleLocationPermission(context) async {

    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Location services are disabled. Please enable the services')));
      return false;
    }
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permissions are denied')));
        return false;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Location permissions are permanently denied, we cannot request permissions.')));
      return false;
    }
    return true;
  }

  createMarker(){
    if(mounted){
      setState(() {
        if(_markers.isNotEmpty){
          _markers.removeWhere((element) => element.markerId.value == widget.name);
        }
        if (otherUserPosition != null) {
          _markers.add(
            Marker(
              markerId: MarkerId(widget.name),
              position: LatLng(otherUserPosition!.latitude, otherUserPosition!.longitude),
              icon: appController.originMarker,
              infoWindow: InfoWindow(
                title: widget.name,
              ),

            ),
          );
        }
      });
    }
  }


  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return SafeArea(
      child: Scaffold(
        body: currentPosition == null
            ? SizedBox(
              height: size.height,
              width: size.width,
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text('Please wait a moment...!'),
                  SizedBox(height: 20),
                  CircularProgressIndicator(),
                ],
              ),
            )
            : otherUserPosition == null
            ? SizedBox(
              height: size.height,
              width: size.width,
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text('Getting Destination Location...!'),
                  SizedBox(height: 20),
                  CircularProgressIndicator(),
                ],
              ),
            )
            : GoogleMap(
              zoomControlsEnabled: true,
              zoomGesturesEnabled: true,
              scrollGesturesEnabled: true,
              compassEnabled: true,
              myLocationButtonEnabled: false,
              myLocationEnabled: true,
              circles: {
                Circle(
                  circleId: const CircleId('currentLocation'),
                  center: LatLng(
                    currentPosition!.latitude,
                    currentPosition!.longitude,
                  ),
                  radius: 100,
                  fillColor: Colors.red.withOpacity(0.5),
                  strokeWidth: 0,
                  strokeColor: Theme.of(context).secondaryHeaderColor,
                ),
                Circle(
                  circleId: const CircleId('OtherUser'),
                  center: LatLng(
                    otherUserPosition!.latitude,
                    otherUserPosition!.longitude,
                  ),
                  radius: 100,
                  fillColor: Colors.green.withOpacity(0.5),
                  strokeWidth: 0,
                  strokeColor: Colors.green.shade700,
                ),
              },
              markers: _markers,
              initialCameraPosition: CameraPosition(
                target: LatLng(
                  currentPosition!.latitude,
                  currentPosition!.longitude,
                ),
                zoom: _currentZoom,
              ),
              onMapCreated: (controller) => _onMapCreated(controller),
            ),
      ),
    );
  }
}
