import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Helper class to initialize and configure AI Agent and Pricing Guide features
class ConfigurationHelper {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Initialize default pricing guides for all service categories
  static Future<void> initializeDefaultPricingGuides() async {
    try {
      List<Map<String, dynamic>> categories = [
        {'id': 'plumbing', 'name': 'Plumbing'},
        {'id': 'electrical', 'name': 'Electrical'},
        {'id': 'carpentry', 'name': 'Carpentry'},
        {'id': 'painting', 'name': 'Painting'},
        {'id': 'hvac', 'name': 'HVAC'},
        {'id': 'roofing', 'name': 'Roofing'},
        {'id': 'flooring', 'name': 'Flooring'},
        {'id': 'landscaping', 'name': 'Landscaping'},
        {'id': 'cleaning', 'name': 'Cleaning'},
        {'id': 'general_maintenance', 'name': 'General Maintenance'},
      ];

      for (var category in categories) {
        String categoryId = category['id']!;
        String categoryName = category['name']!;

        // Check if already exists
        DocumentSnapshot doc = await _firestore
            .collection('pricingGuidance')
            .doc(categoryId)
            .get();

        if (!doc.exists) {
          await _firestore.collection('pricingGuidance').doc(categoryId).set({
            'category_name': categoryName,
            'category_id': categoryId,
            'labor_cost_per_hour': _getDefaultLaborCost(categoryName),
            'material_multiplier': 1.5,
            'service_prices': _getDefaultServicePrices(categoryName),
            'notes': {},
            'created_at': FieldValue.serverTimestamp(),
            'updated_at': FieldValue.serverTimestamp(),
            'updated_by': 'System',
          });

          debugPrint('✓ Created pricing guide for: $categoryName');
        } else {
          debugPrint('✓ Pricing guide already exists for: $categoryName');
        }
      }

      debugPrint('✅ All pricing guides initialized successfully!');
    } catch (e) {
      debugPrint('❌ Error initializing pricing guides: $e');
      rethrow;
    }
  }

  /// Get default labor cost based on category
  static double _getDefaultLaborCost(String categoryName) {
    switch (categoryName.toLowerCase()) {
      case 'electrical':
      case 'hvac':
        return 180.0;
      case 'plumbing':
      case 'roofing':
        return 150.0;
      case 'carpentry':
      case 'painting':
      case 'flooring':
        return 130.0;
      case 'landscaping':
      case 'cleaning':
        return 100.0;
      default:
        return 120.0;
    }
  }

  /// Get default service prices based on category
  static Map<String, double> _getDefaultServicePrices(String categoryName) {
    switch (categoryName.toLowerCase()) {
      case 'plumbing':
        return {
          'Leak Repair': 250.0,
          'Pipe Installation': 500.0,
          'Drain Cleaning': 300.0,
          'Toilet Repair': 200.0,
          'Faucet Replacement': 180.0,
          'Water Heater Installation': 1200.0,
          'Garbage Disposal Installation': 250.0,
          'Sewer Line Repair': 800.0,
        };

      case 'electrical':
        return {
          'Wiring Installation': 400.0,
          'Light Fixture Installation': 150.0,
          'Circuit Breaker Repair': 350.0,
          'Outlet Installation': 120.0,
          'Electrical Inspection': 250.0,
          'Ceiling Fan Installation': 200.0,
          'Panel Upgrade': 1500.0,
          'Generator Installation': 2000.0,
        };

      case 'carpentry':
        return {
          'Door Installation': 450.0,
          'Cabinet Repair': 300.0,
          'Deck Building': 2000.0,
          'Furniture Assembly': 200.0,
          'Custom Shelving': 600.0,
          'Trim Installation': 350.0,
          'Window Frame Repair': 280.0,
          'Staircase Repair': 500.0,
        };

      case 'painting':
        return {
          'Interior Painting (per room)': 800.0,
          'Exterior Painting': 1500.0,
          'Wall Repair & Paint': 350.0,
          'Ceiling Painting': 400.0,
          'Door/Trim Painting': 150.0,
          'Deck Staining': 600.0,
          'Cabinet Painting': 700.0,
          'Wallpaper Removal': 400.0,
        };

      case 'hvac':
        return {
          'AC Installation': 2500.0,
          'AC Repair': 300.0,
          'Furnace Installation': 3000.0,
          'Furnace Repair': 350.0,
          'Duct Cleaning': 400.0,
          'Thermostat Installation': 150.0,
          'AC Maintenance': 120.0,
          'Ventilation Installation': 800.0,
        };

      case 'roofing':
        return {
          'Roof Inspection': 200.0,
          'Roof Repair': 500.0,
          'Roof Replacement': 5000.0,
          'Gutter Installation': 800.0,
          'Gutter Cleaning': 150.0,
          'Leak Repair': 400.0,
          'Shingle Replacement': 350.0,
          'Skylight Installation': 1200.0,
        };

      case 'flooring':
        return {
          'Hardwood Installation': 2000.0,
          'Carpet Installation': 1200.0,
          'Tile Installation': 1500.0,
          'Vinyl Installation': 1000.0,
          'Floor Refinishing': 800.0,
          'Floor Repair': 300.0,
          'Subfloor Repair': 500.0,
          'Baseboard Installation': 400.0,
        };

      case 'landscaping':
        return {
          'Lawn Mowing': 80.0,
          'Tree Trimming': 300.0,
          'Garden Design': 500.0,
          'Irrigation Installation': 1000.0,
          'Fence Installation': 1500.0,
          'Patio Construction': 2000.0,
          'Sod Installation': 800.0,
          'Landscape Lighting': 600.0,
        };

      case 'cleaning':
        return {
          'Deep Cleaning': 200.0,
          'Regular Cleaning': 120.0,
          'Carpet Cleaning': 150.0,
          'Window Cleaning': 100.0,
          'Post-Construction Cleaning': 350.0,
          'Move-In/Out Cleaning': 250.0,
          'Pressure Washing': 180.0,
          'Gutter Cleaning': 120.0,
        };

      default:
        return {
          'Basic Service': 200.0,
          'Standard Service': 350.0,
          'Premium Service': 500.0,
          'Emergency Service': 400.0,
          'Consultation': 100.0,
        };
    }
  }

  /// Verify Firebase configuration
  static Future<Map<String, bool>> verifyConfiguration() async {
    Map<String, bool> results = {
      'firestore_connected': false,
      'pricing_collection_exists': false,
      'sessions_collection_exists': false,
      'artisan_contacts_collection_exists': false,
    };

    try {
      // Test Firestore connection
      await _firestore.collection('test').limit(1).get();
      results['firestore_connected'] = true;

      // Check pricing guidance collection
      // A collection with zero documents is still valid.
      await _firestore.collection('pricingGuidance').limit(1).get();
      results['pricing_collection_exists'] = true;

      // Check AI agent sessions collection
      // NOTE: Firestore doesn't have a true "collection exists" concept.
      // A collection with zero documents is still valid. The check passes
      // as long as reads are allowed and the query succeeds.
      await _firestore.collection('aiAgentSessions').limit(1).get();
      results['sessions_collection_exists'] = true;

      // Check artisan contacts collection
      // NOTE: Firestore doesn't have a true "collection exists" concept.
      // A collection with zero documents is still valid. This check should pass
      // as long as reads are allowed and the query succeeds.
      await _firestore.collection('artisanContacts').limit(1).get();
      results['artisan_contacts_collection_exists'] = true;
    } catch (e) {
      debugPrint('Error verifying configuration: $e');
    }

    return results;
  }

  /// Print configuration status
  static Future<void> printConfigurationStatus() async {
    debugPrint('========================================');
    debugPrint('AI Agent Configuration Status');
    debugPrint('========================================');

    Map<String, bool> status = await verifyConfiguration();

    status.forEach((key, value) {
      String icon = value ? '✅' : '❌';
      debugPrint('$icon $key: ${value ? 'OK' : 'NOT FOUND'}');
    });

    debugPrint('========================================');

    // Count pricing guides
    try {
      var pricingDocs = await _firestore.collection('pricingGuidance').get();
      debugPrint('📊 Total Pricing Guides: ${pricingDocs.docs.length}');

      for (var doc in pricingDocs.docs) {
        var data = doc.data();
        debugPrint(
            '   - ${data['category_name']}: ${data['service_prices'].length} services');
      }
    } catch (e) {
      debugPrint('❌ Error counting pricing guides: $e');
    }

    debugPrint('========================================');
  }

  /// Create a test AI session (for testing purposes)
  static Future<void> createTestSession() async {
    try {
      String sessionId = 'test_${DateTime.now().millisecondsSinceEpoch}';

      await _firestore.collection('aiAgentSessions').doc(sessionId).set({
        'sessionId': sessionId,
        'state': 'completed',
        'currentStep': 'completedSuccess',
        'collectedData': {
          'category': 'Plumbing',
          'description': 'Test leak repair',
          'requirements': 'Urgent',
          'location': 'Test Address',
          'timing': 'Today',
        },
        'imageUrls': [],
        'selectedArtisanId': null,
        'startTime': FieldValue.serverTimestamp(),
        'conversationHistory': [
          {
            'id': '1',
            'sender': 'agent',
            'text': 'Hello! How can I help you today?',
            'timestamp': DateTime.now().toIso8601String(),
            'type': 'voice',
          },
          {
            'id': '2',
            'sender': 'client',
            'text': 'I need plumbing service',
            'timestamp': DateTime.now().toIso8601String(),
            'type': 'voice',
          },
        ],
      });

      debugPrint('✅ Test session created: $sessionId');
    } catch (e) {
      debugPrint('❌ Error creating test session: $e');
    }
  }

  /// Cleanup test data
  static Future<void> cleanupTestData() async {
    try {
      // Delete test sessions
      var testSessions = await _firestore
          .collection('aiAgentSessions')
          .where('sessionId', isGreaterThanOrEqualTo: 'test_')
          .where('sessionId', isLessThan: 'test_~')
          .get();

      for (var doc in testSessions.docs) {
        await doc.reference.delete();
      }

      debugPrint('✅ Cleaned up ${testSessions.docs.length} test sessions');
    } catch (e) {
      debugPrint('❌ Error cleaning up test data: $e');
    }
  }

  /// Show configuration dialog in app
  static Future<void> showConfigurationDialog(BuildContext context) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Initializing Configuration'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Setting up AI Agent and Pricing Guides...'),
          ],
        ),
      ),
    );

    try {
      await initializeDefaultPricingGuides();
      Map<String, bool> status = await verifyConfiguration();

      if (context.mounted) {
        Navigator.pop(context); // Close loading dialog

        // Show results
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Configuration Complete'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: status.entries.map((entry) {
                return ListTile(
                  leading: Icon(
                    entry.value ? Icons.check_circle : Icons.error,
                    color: entry.value ? Colors.green : Colors.red,
                  ),
                  title: Text(
                    entry.key.replaceAll('_', ' ').toUpperCase(),
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Text(entry.value ? 'OK' : 'FAILED'),
                );
              }).toList(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Configuration failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
