//
//  MapDatum.swift
//  Conduit
//
//  Apple Maps in mainland China works in GCJ-02, the shifted datum Chinese
//  law requires: its tiles, search results and routes sit a few hundred
//  metres from the WGS-84 that Core Location measures (#1122). Conduit
//  keeps saved places and fixes in WGS-84 and converts where MapKit is on
//  the other side: what MapKit hands back is read with `fromMap`, what is
//  drawn or routed in MapKit goes through `toMap`. Outside mainland China
//  both are the identity.
//
//  Shared with the Location Push extension, which routes saved places.
//

import CoreLocation
import Foundation

enum MapDatum {
    /// A WGS-84 coordinate as Apple Maps places it.
    static func toMap(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isShifted(coordinate) else { return coordinate }
        let shift = offset(coordinate)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + shift.latitude,
                                      longitude: coordinate.longitude + shift.longitude)
    }

    /// A coordinate read from Apple Maps (a search result, a map item) in WGS-84.
    static func fromMap(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isShifted(coordinate) else { return coordinate }
        // The shift has no closed inverse: step back until the forward shift lands
        // on the map's point. It converges to well under a millimetre in a few steps.
        var wgs = coordinate
        for _ in 0..<10 {
            let shift = offset(wgs)
            let errorLatitude = wgs.latitude + shift.latitude - coordinate.latitude
            let errorLongitude = wgs.longitude + shift.longitude - coordinate.longitude
            wgs = CLLocationCoordinate2D(latitude: wgs.latitude - errorLatitude, longitude: wgs.longitude - errorLongitude)
            if abs(errorLatitude) < 1e-9 && abs(errorLongitude) < 1e-9 { break }
        }
        return wgs
    }

    /// Whether Apple Maps shifts this point: mainland China, not Hong Kong,
    /// Macau or Taiwan, nor the neighbours inside China's bounding box. Boxes
    /// are north, west, south, east; borders are approximate to a few km.
    static func isShifted(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return false }
        let inside = { (box: Box) in
            coordinate.latitude <= box.north && coordinate.latitude >= box.south
                && coordinate.longitude >= box.west && coordinate.longitude <= box.east
        }
        return mainland.contains(where: inside) && !excluded.contains(where: inside)
    }

    private typealias Box = (north: Double, west: Double, south: Double, east: Double)

    private static let mainland: [Box] = [
        (49.2204, 79.4462, 42.8899, 96.3300),
        (54.1415, 109.6872, 39.3742, 135.0002),
        (42.8899, 73.1246, 29.5297, 124.143255),
        (29.5297, 82.9684, 26.7186, 97.0352),
        (29.5297, 97.0253, 20.414096, 124.367395),
        (20.414096, 107.975793, 17.871542, 111.744104),
    ]

    private static let excluded: [Box] = [
        (25.398623, 119.921265, 21.785006, 122.497559), // Taiwan
        (22.2840, 101.8652, 20.0988, 106.6650),          // Laos and Vietnam
        (21.5422, 106.4525, 20.4878, 108.0510),          // Vietnam
        (55.8175, 109.0323, 50.3257, 119.1270),          // Mongolia and Russia
        (55.8175, 127.4568, 49.5574, 137.0227),          // Russia
        (44.8922, 131.2662, 42.5692, 137.0227),          // Russia
        (22.4300, 113.8200, 22.1500, 114.4500),          // Hong Kong: Lantau, Kowloon, the island
        (22.5000, 113.9600, 22.4300, 114.4500),          // Hong Kong: New Territories, south of Shenzhen
        (22.2200, 113.5200, 22.1000, 113.6000),          // Macau
    ]

    private static let semiMajorAxis = 6_378_245.0
    private static let eccentricitySquared = 0.00669342162296594323

    /// The GCJ-02 shift at a WGS-84 point, in degrees.
    private static func offset(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let x = coordinate.longitude - 105
        let y = coordinate.latitude - 35
        let latitude = coordinate.latitude * .pi / 180
        let magic = 1 - eccentricitySquared * sin(latitude) * sin(latitude)
        let rootMagic = magic.squareRoot()
        let shiftLatitude = latitudeShift(x, y) * 180
            / ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * rootMagic) * .pi)
        let shiftLongitude = longitudeShift(x, y) * 180 / (semiMajorAxis / rootMagic * cos(latitude) * .pi)
        return CLLocationCoordinate2D(latitude: shiftLatitude, longitude: shiftLongitude)
    }

    private static func latitudeShift(_ x: Double, _ y: Double) -> Double {
        var shift = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * abs(x).squareRoot()
        shift += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        shift += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        shift += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        return shift
    }

    private static func longitudeShift(_ x: Double, _ y: Double) -> Double {
        var shift = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * abs(x).squareRoot()
        shift += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        shift += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        shift += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        return shift
    }
}
