//
//  Created by Danijel Huis on 22/04/15.
//  Copyright (c) 2015 Danijel Huis. All rights reserved.
//
// 2016 AIS Hackhathon 
// Pedro Fabrino, Lucas Neves, Jonathan Nobre

import UIKit
import CoreMotion
import CoreLocation


@objc protocol FindrTrackingManagerDelegate : NSObjectProtocol
{
    @objc optional func findrTrackingManager(_ trackingManager: FindrTrackingManager, didUpdateUserLocation location: CLLocation?)
    @objc optional func findrTrackingManager(_ trackingManager: FindrTrackingManager, didUpdateReloadLocation location: CLLocation?)
    @objc optional func onUserAppearLost(_ trackingManager: FindrTrackingManager, didUpdateReloadLocation location: CLLocation?)
    @objc optional func logText(_ text: String)
}


/// Class used internally by ARViewController for location and orientation calculations.
open class FindrTrackingManager: NSObject, CLLocationManagerDelegate
{
    /**
     *      Defines whether altitude is taken into account when calculating distances. Set this to false if your annotations 
     *      don't have altitude values. Note that this is only used for distance calculation, it doesn't have effect on vertical 
     *      levels of annotations. Default value is false.
     */
    open var altitudeSensitive = false 
 
    /**
     *      Specifies how often the visibilities of annotations are reevaluated.
     *
     *      Annotation's visibility depends on number of factors - azimuth, distance from user, vertical level etc.
     *      Note: These calculations are quite heavy if many annotations are present, so don't use value lower than 50m.
     *      Default value is 75m.
     *
     */
    open var reloadDistanceFilter: CLLocationDistance!    // Will be set in init
    
    /**
     *      Specifies how often are distances and azimuths recalculated for visible annotations.
     *      Default value is 25m.
     */
    open var userDistanceFilter: CLLocationDistance!      // Will be set in init
    {
        didSet
        {
            self.locationManager.distanceFilter = self.userDistanceFilter
        }
    }
    
    
    open var motionManager: CMMotionManager = CMMotionManager()
    
    //===== Internal variables
    fileprivate(set) internal var locationManager: CLLocationManager = CLLocationManager()
    fileprivate(set) internal var tracking = false
    fileprivate(set) internal var userLocation: CLLocation?
    fileprivate(set) internal var heading: Double = 0
    internal var delegate: FindrTrackingManagerDelegate?
    internal var orientation: CLDeviceOrientation = CLDeviceOrientation.portrait
    {
        didSet
        {
            self.locationManager.headingOrientation = self.orientation
        }
    }
    internal var pitch: Double
    {
        get
        {
            return self.calculatePitch()
        }
    }
    
    //===== Private variables
    fileprivate var lastAcceleration: CMAcceleration = CMAcceleration(x: 0, y: 0, z: 0)
    fileprivate var reloadLocationPrevious: CLLocation?
    fileprivate var pitchPrevious: Double = 0
    fileprivate var reportLocationTimer: Timer?
    fileprivate var reportLocationDate: TimeInterval?
    fileprivate var debugLocation: CLLocation?
    


    override init()
    {
        super.init()
        self.initialize()
    }
    
    fileprivate func initialize()
    {
        // Defaults
        self.reloadDistanceFilter = 75
        self.userDistanceFilter = 25
        
        // Setup location manager
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
//        self.locationManager.distanceFilter = CLLocationDistance(self.userDistanceFilter)
        self.locationManager.headingFilter = 1
        self.locationManager.delegate = self
    }
    
    //==========================================================================================================================================================
    // MARK:                                                        Tracking
    //==========================================================================================================================================================

    /// Starts location and motion manager
    internal func startTracking()
    {
        // Request authorization if state is not determined
        if CLLocationManager.locationServicesEnabled()
        {
            if CLLocationManager.authorizationStatus() == CLAuthorizationStatus.notDetermined
            {
                self.locationManager.requestWhenInUseAuthorization()
//                if #available(iOS 8.0, *)
//                {
//                    
//                }
//                else
//                {
//                    // Fallback on earlier versions
//                }
                
            }
        }
        
        // Start motion and location managers
        self.motionManager.startAccelerometerUpdates()
        self.motionManager.startMagnetometerUpdates()
//        self.motionManager.gyroUpdateInterval = 0.5
        self.locationManager.startUpdatingHeading()
        self.locationManager.startUpdatingLocation()
        
        self.tracking = true
    }
    
    /// Stops location and motion manager
    internal func stopTracking()
    {
        self.reloadLocationPrevious = nil
        self.userLocation = nil
        self.reportLocationDate = nil
        
        // Stop motion and location managers
        self.motionManager.stopAccelerometerUpdates()
        self.motionManager.stopMagnetometerUpdates()
        self.locationManager.stopUpdatingHeading()
        self.locationManager.stopUpdatingLocation()
        
        self.tracking = false
    }
    
    //==========================================================================================================================================================
    // MARK:                                                        CLLocationManagerDelegate
    //==========================================================================================================================================================

    open func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading)
    {
        self.heading = fmod(newHeading.trueHeading, 360.0)
    }
    
    open func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation])
    {
        if locations.count > 0
        {
            let location = locations[0]

            // Disregarding old and low quality location detections
            let age = location.timestamp.timeIntervalSinceNow;
            if age < -30 || location.horizontalAccuracy > 500 || location.horizontalAccuracy < 0
            {
                print("Disregarding location: age: \(age), ha: \(location.horizontalAccuracy)")
                return
            }
            
            //println("== \(location!.horizontalAccuracy), \(age) \(location!.coordinate.latitude), \(location!.coordinate.longitude)" )
            self.userLocation = location
            
            // Setting altitude to 0 if altitudeSensitive == false
            if self.userLocation != nil && !self.altitudeSensitive
            {
                let location = self.userLocation!
                self.userLocation = CLLocation(coordinate: location.coordinate, altitude: 0, horizontalAccuracy: location.horizontalAccuracy, verticalAccuracy: location.verticalAccuracy, timestamp: location.timestamp)
            }
            
            if debugLocation != nil {self.userLocation = debugLocation}
            
            if self.reloadLocationPrevious == nil
            {
                self.reloadLocationPrevious = self.userLocation
            }
            
            //===== Reporting location 5s after we get location, this will filter multiple locations calls and make only one delegate call
            let reportIsScheduled = self.reportLocationTimer != nil
            
            // First time, reporting immediately
            if self.reportLocationDate == nil
            {
                self.reportLocationToDelegate()
            }
            // Report is already scheduled, doing nothing, it will report last location delivered in that 5s
            else if reportIsScheduled
            {
                
            }
            // Scheduling report in 5s
            else
            {
                self.reportLocationTimer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(FindrTrackingManager.reportLocationToDelegate), userInfo: nil, repeats: false)
            }
        }
    }
    
    internal func reportLocationToDelegate()
    {
        self.delegate?.findrTrackingManager?(self, didUpdateUserLocation: self.userLocation)
        
        if self.userLocation != nil && self.reloadLocationPrevious != nil && self.reloadLocationPrevious!.distance(from: self.userLocation!) > self.reloadDistanceFilter
        {
            self.reloadLocationPrevious = self.userLocation
            self.delegate?.findrTrackingManager?(self, didUpdateReloadLocation: self.userLocation)
        }
        
        self.reportLocationTimer?.invalidate()
        self.reportLocationTimer = nil
        self.reportLocationDate = Date().timeIntervalSince1970
    }
    
    
    
    //==========================================================================================================================================================
    // MARK:                                                        Calculations
    //==========================================================================================================================================================
    internal func calculatePitch() -> Double
    {
        if self.motionManager.accelerometerData == nil
        {
            return 0
        }
        
        let acceleration: CMAcceleration = self.motionManager.accelerometerData!.acceleration
        
        // Filtering data so its not jumping around
        let filterFactor: Double = 0.05
        self.lastAcceleration.x = (acceleration.x * filterFactor) + (self.lastAcceleration.x  * (1.0 - filterFactor));
        self.lastAcceleration.y = (acceleration.y * filterFactor) + (self.lastAcceleration.y  * (1.0 - filterFactor));
        self.lastAcceleration.z = (acceleration.z * filterFactor) + (self.lastAcceleration.z  * (1.0 - filterFactor));
        
        let deviceOrientation = self.orientation
        var angle: Double = 0
        
        if deviceOrientation == CLDeviceOrientation.portrait
        {
            angle = atan2(self.lastAcceleration.y, self.lastAcceleration.z)
        }
        else if deviceOrientation == CLDeviceOrientation.portraitUpsideDown
        {
            angle = atan2(-self.lastAcceleration.y, self.lastAcceleration.z)
        }
        else if deviceOrientation == CLDeviceOrientation.landscapeLeft
        {
            angle = atan2(self.lastAcceleration.x, self.lastAcceleration.z)
        }
        else if deviceOrientation == CLDeviceOrientation.landscapeRight
        {
            angle = atan2(-self.lastAcceleration.x, self.lastAcceleration.z)
        }
        
        angle += M_PI_2
        angle = (self.pitchPrevious + angle) / 2.0
        self.pitchPrevious = angle
        return angle
    }
    
    internal func azimuthFromUserToLocation(_ location: CLLocation) -> Double
    {
        var azimuth: Double = 0
        if self.userLocation == nil
        {
            return 0
        }
                
        let coordinate: CLLocationCoordinate2D = location.coordinate
        let userCoordinate: CLLocationCoordinate2D = self.userLocation!.coordinate
        
        // Calculating azimuth
        let latitudeDistance: Double = userCoordinate.latitude - coordinate.latitude;
        let longitudeDistance: Double = userCoordinate.longitude - coordinate.longitude;
       
        // Simplified azimuth calculation
        azimuth = radiansToDegrees(atan2(longitudeDistance, (latitudeDistance * Double(LAT_LON_FACTOR))))
        
//        TODO: Não TIREI 40
        azimuth += 180.0
        
        return azimuth;
    }
    
    internal func startDebugMode(_ location: CLLocation)
    {
        self.debugLocation = location
        self.userLocation = location;
    }
    internal func stopDebugMode(_ location: CLLocation)
    {
        self.debugLocation = nil;
        self.userLocation = nil
    }
    
}


































