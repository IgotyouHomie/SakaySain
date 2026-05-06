/// ╔══════════════════════════════════════════════════════════════════════════╗
/// ║                  SAKAYSAIN - FEATURES 9-12 IMPLEMENTATION                ║
/// ║               Passenger Validation, Mode, Exit & Ghost Jeep              ║
/// ╚══════════════════════════════════════════════════════════════════════════╝
///
/// This document explains the complete implementation of Features 9-12 in the
/// SakaySain crowdsourced jeep tracking application.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// ARCHITECTURE OVERVIEW
/// ═══════════════════════════════════════════════════════════════════════════
///
/// The implementation consists of three main services:
///
/// 1. PassengerService (passenger_service.dart)
///    └─ Manages passenger lifecycle: validation, mode, exit
///    └─ Handles 5-minute validation countdown
///    └─ Records journey data (route, speed, chunks, stops)
///
/// 2. GhostJeepService (ghost_jeep_service.dart)
///    └─ Predicts jeep movement after passenger exits
///    └─ Uses historical routes, traffic, confidence decay
///    └─ Enables tracking of jeeps without active passengers
///
/// 3. RoadIntelligenceService (road_intelligence_service.dart)
///    └─ Provides crowd-sourced road intelligence
///    └─ Updates every 2 minutes with nearest chunk data
///    └─ Shows: wait times, common jeeps, activity level
///
/// UI Screens:
/// • PassengerValidationScreen - 5-minute countdown validation
/// • PassengerModeScreen - Shows user as green square during ride
///
/// ═══════════════════════════════════════════════════════════════════════════
/// FEATURE 9: PASSENGER VALIDATION
/// ═══════════════════════════════════════════════════════════════════════════
///
/// FLOW:
/// 1. User confirms jeep in Find Jeep Flow (arrived state)
/// 2. Taps "Verify your Jeep" button
/// 3. PassengerValidationScreen shows:
///    - 5-minute countdown timer (MM:SS format)
///    - Validation conditions checklist
///    - Jeep type and ID info
///
/// CONDITIONS FOR VALIDATION SUCCESS:
/// ✓ User near snapzone (within 30m of road chunk)
/// ✓ Jeep confirmed by user
/// ✓ User moving at vehicle speed (auto-detected)
/// ✓ 5-minute timer expires without cancellation
///
/// VALIDATION FAILURE:
/// - If user moves >100m from waiting pin → validation cancelled
/// - If user cancels manually → "Fake report cancelled"
/// - If timeout expires → 5 minutes of location tracking
///
/// IMPLEMENTATION:
/// ```dart
/// // Start validation
/// PassengerService().startValidation(jeepId, jeepType, location);
///
/// // In screen - listen to validation timer
/// PassengerService().validationSecondsRemaining // 300 to 0
///
/// // Validation complete triggers automatic transition
/// PassengerService().status == PassengerStatus.passenger
/// ```
///
/// ═══════════════════════════════════════════════════════════════════════════
/// FEATURE 10: PASSENGER MODE
/// ═══════════════════════════════════════════════════════════════════════════
///
/// TRIGGERED BY:
/// - Automatic transition after 5-minute validation completes
///
/// UI DISPLAY:
/// - User becomes GREEN SQUARE on map (instead of arrow marker)
/// - Shows live passenger tracking to other users
/// - Displays: Jeep ID, Jeep Type, Trip Duration, Current Location
/// - Live updates every 1-3 meters
///
/// DATA COLLECTION:
/// PassengerJourneyData records:
/// • Route points (latitude, longitude array)
/// • Speeds at each location
/// • Chunk pass times (when jeep passes chunk boundaries)
/// • Stop count (when jeep velocity = 0)
/// • Jeep type consistency
/// • Traffic patterns
/// • Confidence score
///
/// PURPOSE:
/// "Crowdsourced live jeep data" - feeds into:
/// - Backend model training
/// - Ghost jeep predictions
/// - Route pattern recognition
/// - Traffic prediction
///
/// IMPLEMENTATION:
/// ```dart
/// // Update location while passenger
/// PassengerService().updatePassengerLocation(latLng, speed);
///
/// // Record chunk traversal
/// PassengerService().recordChunkPass(timestamp);
///
/// // Get current journey
/// var journey = PassengerService().currentJourney;
/// ```
///
/// ═══════════════════════════════════════════════════════════════════════════
/// FEATURE 11: PASSENGER EXIT
/// ═══════════════════════════════════════════════════════════════════════════
///
/// EXIT TRIGGERS:
/// 1. User manually taps "Exit Trip" button
/// 2. User moves >100m from road (leaves road)
/// 3. User velocity drops to 0 for >30 seconds (stops)
/// 4. User ends app / session
///
/// EXIT SEQUENCE:
/// 1. Stop location tracking
/// 2. Status: passenger → exiting (transition state)
/// 3. Save journey data (completed PassengerJourneyData)
/// 4. Register with GhostJeepService for prediction
/// 5. Record activity in RoadIntelligenceService
/// 6. Status: exiting → bystander
/// 7. Return to main screen
///
/// JOURNEY DATA SAVED INCLUDES:
/// - Complete route path
/// - Speed profile
/// - Chunk traversal times
/// - Stop locations and durations
/// - Time in vehicle
/// - Confidence metrics
///
/// USES OF SAVED DATA:
/// • Backend data labeling
/// • Model training
/// • Route pattern databases
/// • Traffic pattern databases
///
/// ═══════════════════════════════════════════════════════════════════════════
/// FEATURE 12: GHOST JEEP SYSTEM (V2)
/// ═══════════════════════════════════════════════════════════════════════════
///
/// PURPOSE:
/// Predict jeep movement even when NO active passengers are tracking it.
/// Enables system to "see" jeeps that aren't being directly observed.
///
/// PREDICTION INPUTS:
/// 1. Last route taken (PassengerJourneyData.routePoints)
/// 2. Historical route loops (past journeys of same jeep)
/// 3. Chunk flow patterns (how jeeps navigate chunks)
/// 4. Jeep type behavior (different jeeps drive differently)
/// 5. Traffic conditions (current speed adjustments)
/// 6. Confidence decay (older sightings = lower confidence)
///
/// PREDICTION CALCULATION:
/// ```
/// Step 1: Extract last known position and direction
/// Step 2: Calculate average speed from journey data
/// Step 3: Adjust speed by traffic factor (0.5-2.0x)
/// Step 4: Project distance traveled = speed × elapsed time
/// Step 5: Find next position along projected route
/// Step 6: Calculate confidence based on:
///    - History depth (more history = higher)
///    - Route consistency (similar paths = higher)
///    - Time decay (newer = higher)
///    - Traffic uncertainty (certain traffic = higher)
/// Step 7: Apply linear confidence decay (-2% per minute)
/// ```
///
/// CONFIDENCE LEVELS:
/// • VeryHigh (>90%)  - High history, consistent routes, fresh data
/// • High (70-90%)    - Good history, reasonable patterns
/// • Medium (50-70%)  - Some history, uncertain traffic
/// • Low (30-50%)     - Limited history, old data
/// • VeryLow (<30%)   - Sparse history, very old sighting
///
/// CONFIDENCE DECAY:
/// Confidence decays at 2% per minute to account for:
/// - Changing traffic patterns
/// - Jeep breakdowns or diversions
/// - Changed jeep driver behavior
/// - Route variations
///
/// EXAMPLE TIMELINE:
/// ```
/// T+0min:   Confidence 90% (VeryHigh)
/// T+5min:   Confidence 80% (High)   [90 - (5×2%)]
/// T+10min:  Confidence 70% (High)   [90 - (10×2%)]
/// T+20min:  Confidence 50% (Medium) [90 - (20×2%)]
/// T+30min:  Confidence 30% (Low)    [90 - (30×2%)] - prediction stops
/// ```
///
/// IMPLEMENTATION:
/// ```dart
/// // Register passenger exit to track jeep
/// GhostJeepService().registerPassengerExit(journeyData, trafficFactor);
///
/// // Get active predictions
/// var predictions = GhostJeepService().activePredictions;
///
/// // Use prediction in UI
/// var pred = predictions['JEEP_123'];
/// _showGhostJeepOnMap(
///   pred.predictedPosition,
///   confidence: pred.confidence,
///   confidenceDecay: pred.confidenceDecay,  // 0.0-1.0
/// );
/// ```
///
/// ═══════════════════════════════════════════════════════════════════════════
/// ROAD INTELLIGENCE SERVICE (Bonus: Enhanced Main Screen)
/// ═══════════════════════════════════════════════════════════════════════════
///
/// PURPOSE:
/// Display crowd-sourced intelligence about nearest road chunks in real-time.
/// Helps users make informed decisions about jeep hunting.
///
/// DATA DISPLAYED:
/// Updated every 2 minutes when user is on map:
///
/// • Nearest Road Chunk ID
///   - Which chunk is closest to user
///   - "--" until user within 30m (snapzone)
///
/// • Average Wait Time
///   - Rolling average of actual wait times
///   - Example: "2-5 min"
///   - "--" without data
///
/// • Common Jeeps
///   - Most frequent jeep types at this chunk
///   - Example: "A, B, C"
///   - Comma-separated list
///   - "--" without data
///
/// • Activity Level
///   - How busy the chunk is: "High", "Medium", "Low"
///   - Based on jeep frequency and passengers
///   - "--" without data
///
/// • Active Jeeps Nearby (Top Header)
///   - Count of jeeps within 500m
///   - Based on GhostJeepService predictions
///   - Real-time updated
///
/// • Last Jeep Passed (Top Header)
///   - When was last jeep sighted
///   - Example: "12s ago"
///   - "--" without data
///
/// UPDATE MECHANISM:
/// ```
/// On LocationUpdate:
///  ├─ Check if >500m from last update → full refresh
///  └─ Keep local cache otherwise
///
/// Every 2 minutes:
///  └─ Force refresh of all intelligence
///
/// Snapzone Detection:
///  ├─ Within 30m → show real data
///  └─ Beyond 30m → show "--" placeholders
/// ```
///
/// DATA SOURCES (in production):
/// • Backend crowd-sourced database
/// • Historical journey archives
/// • Real-time GhostJeep predictions
/// • Active PassengerService trackers
/// • Traffic incident reports
///
/// ═══════════════════════════════════════════════════════════════════════════
/// INTEGRATION WITH EXISTING FEATURES
/// ═══════════════════════════════════════════════════════════════════════════
///
/// find_jeep_flow.dart changes:
/// • State: arrived → Tap "Verify your Jeep"
/// • Navigates to PassengerValidationScreen
/// • On validation complete → PassengerModeScreen
/// • On exit → returns to main_screen
///
/// main_screen.dart changes:
/// • Stats now from RoadIntelligenceService
/// • Updates every 2 minutes automatically
/// • Shows real data when near roads, "--" otherwise
/// • Active jeeps count + last jeep passed integrated
///
/// DATA FLOW:
/// ```
/// find_jeep_flow.dart
///   ↓ (onVerifyJeep)
/// PassengerValidationScreen (Feature 9)
///   ↓ (validation complete)
/// PassengerModeScreen (Feature 10)
///   ↓ (user exits)
/// GhostJeepService + RoadIntelligenceService (Features 11+12)
///   ↓ (data recorded)
/// Backend server (mock in dev)
/// ```
///
/// ═══════════════════════════════════════════════════════════════════════════
/// MOCK DATA & TESTING
/// ═══════════════════════════════════════════════════════════════════════════
///
/// For development, all three services include mock implementations:
///
/// RoadIntelligenceService:
/// • Generates grid of 9 chunks around user (3x3)
/// • Random wait times, jeeps, activity levels
/// • Only real data within 30m snapzone
/// • Realistic values: wait time 2-8min, 1-5 jeeps, high/med/low activity
///
/// GhostJeepService:
/// • Stores history of all passengers
/// • Predicts forward along last route
/// • Linear distance projection
/// • Confidence decay system
/// • Can be visualized on map
///
/// PassengerService:
/// • Full lifecycle simulation
/// • Real location tracking
/// • Journey data collection
/// • 5-minute validation works offline
///
/// ═══════════════════════════════════════════════════════════════════════════
/// ERROR HANDLING & EDGE CASES
/// ═══════════════════════════════════════════════════════════════════════════
///
/// Validation Cancelled:
/// ✓ User moves >100m → auto-cancel
/// ✓ Manual cancel button → immediate stop
/// ✓ Location unavailable → stop with error
///
/// Passenger Mode:
/// ✓ Location unavailable → continue with last known
/// ✓ Network unavailable → buffer data locally
/// ✓ App backgrounded → pause tracking
///
/// Ghost Jeep:
/// ✓ No history → default prediction (straight forward)
/// ✓ Traffic unavailable → use speed=1.0
/// ✓ Route ends → stop prediction
///
/// ═══════════════════════════════════════════════════════════════════════════
/// FUTURE ENHANCEMENTS
/// ═══════════════════════════════════════════════════════════════════════════
///
/// Phase 2 (Next Sprint):
/// • Backend API integration for real data
/// • Kalman filtering for better predictions
/// • Machine learning model for confidence
/// • Real-time map rendering of ghost jeeps
/// • Passenger rating system integration
///
/// Phase 3 (Future):
/// • Multi-jeep interaction handling
/// • Cross-route prediction
/// • Traffic incident detection
/// • Anomaly detection for fake reports
/// • Advanced clustering for popular routes
///
/// ═══════════════════════════════════════════════════════════════════════════
/// FILES CREATED
/// ═══════════════════════════════════════════════════════════════════════════
///
/// Services:
/// • lib/services/passenger_service.dart (428 lines)
/// • lib/services/ghost_jeep_service.dart (463 lines)
/// • lib/services/road_intelligence_service.dart (354 lines)
///
/// Screens:
/// • lib/screens/passenger_mode_screen.dart (495 lines)
///
/// Modified:
/// • lib/screens/main_screen.dart (integrated RoadIntelligenceService)
/// • lib/screens/find_jeep_flow.dart (integrated PassengerValidation)
///
/// ═══════════════════════════════════════════════════════════════════════════
/// USAGE QUICK START
/// ═══════════════════════════════════════════════════════════════════════════
///
/// 1. Start app normally → main_screen shown
/// 2. Road intelligence automatically starts (2-min refresh)
/// 3. Tap "Find Nearby Jeep" → find_jeep_flow
/// 4. Place waiting pin → select jeep type → wait for arrival
/// 5. Jeep arrives → tap "Jeep Arrived"
/// 6. Fill in star rating → tap "Verify your Jeep"
/// 7. PassengerValidationScreen shows 5:00 countdown
/// 8. Wait for validation OR tap "Cancel" for fake report
/// 9. After 5min → automatically enter PassengerModeScreen
/// 10. Tap "Exit Trip" or let it auto-exit when stationary
/// 11. Return to main_screen with updated intelligence
///
/// All data is recorded and ready for backend submission or ghost predictions!
///
/// ═══════════════════════════════════════════════════════════════════════════

