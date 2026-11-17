//created by Josh Clark
import CoreLocation
import MapKit
import Combine
import UserNotifications

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var location: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var region: MKCoordinateRegion // Pre-calculated nearby stores

    private let locationManager: CLLocationManager?
    private var hasConfiguredGeofences = false
    
    /// Returns true if running in an app extension (which can't use background location)
    private var isRunningInExtension: Bool {
        return Bundle.main.bundlePath.hasSuffix(".appex")
    }
    /// Store list is large; keep it static so it isn't rebuilt per LocationManager instance.
    static let predefinedStores: [Store] = [
        Store(name: "Pak’nSave Lincoln North", vicinity: "192-198 Universal Drive, Henderson", latitude: -36.8567788, longitude: 174.6285432, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 833 5072", website: "https://www.paknsave.co.nz"),
        Store(name: "Pak’nSave Ormiston", vicinity: "240 Ormiston Road, Flat Bush", latitude: -36.964715, longitude: 174.914952, storehours: "Mon-Sun: 7:30am - 10:00pm", phoneNumber: "+64 9 265 6080", website: "https://www.paknsave.co.nz/stores"),
        Store(name: "Pak’nSave Royal Oak", vicinity: "691 Manukau Road, Royal Oak", latitude: -36.909779, longitude: 174.7746137, storehours: "Mon-Sun: 7:30am - 10:00pm", phoneNumber: "+64 9 625 8939", website: "https://www.paknsave.co.nz/stores"),
        Store(name: "Pak’nSave Westgate", vicinity: "17/19 Fred Taylor Dr, Massey", latitude: -36.820473, longitude: 174.608575, storehours: "Mon-Sun: 8:00am - 10:00pm", phoneNumber: "+64 9 831 0200", website: "https://www.paknsave.co.nz/stores"),
        Store(name: "Pak’nSave Sylvia Park", vicinity: "286 Mount Wellington Highway, Mount Wellington", latitude: -36.913203, longitude: 174.839940, storehours: "Mon-Sun: 7:30am - 10:00pm", phoneNumber: "+64 9 573 0783", website: "https://www.paknsave.co.nz"),
        Store(name: "Countdown Sylvia Park", vicinity: "Cnr Penrose Rd, Moutn Wellington Highway, Mount Wellington", latitude: -36.909528, longitude: 174.837208, storehours: "Mon-Sun: 7:30am - 10:00pm", phoneNumber: "+64 9 573 0783", website: "https://www.paknsave.co.nz"),
        Store(name: "Pak’nSave Māngere", vicinity: "Corner of Bader Drive and Orly Avenue, Māngere", latitude: -36.968445, longitude: 174.796921, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 275 0130", website: "https://www.paknsave.co.nz/stores"),
        Store(name: "Countdown Botany Downs", vicinity: "Cnr Te Irirangi Drive, Ti Rakau Drive, Botany", latitude: -36.930086, longitude: 174.910929, storehours: "Mon-Sun: 7:00am - Midnight", phoneNumber: "+64 9 273 9050", website: "https://www.countdown.co.nz"),
        Store(name: "Countdown Glenfield", vicinity: "Corner Glenfield Road & Downing Street, Glenfield", latitude: -36.781729, longitude: 174.722826, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 443 4477", website: "https://www.countdown.co.nz"),
        Store(name: "Countdown Westgate", vicinity: "Fred Taylor Drive, Westgate", latitude: -36.821407, longitude: 174.614344, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 833 8499", website: "https://www.countdown.co.nz"),
        Store(name: "Countdown Manukau", vicinity: "652 Greath South Road, Manukau City", latitude: -36.986689, longitude: 174.884316, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 261 2456", website: "https://www.countdown.co.nz"),
        Store(name: "Countdown Manukau City", vicinity: "Shop 99, Wirir Station Road, Great South Road, Manukau City", latitude: -36.991924, longitude: 174.882599, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 261 2456", website: "https://www.countdown.co.nz"),
        Store(name: "Countdown Newmarket", vicinity: "277 Broadway, Newmarket", latitude: -36.868754, longitude: 174.778278, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 520 3117", website: "https://www.countdown.co.nz"),
        Store(name: "Tesco Yeovil Extra", vicinity: "2 Cavalier Way, Yeovil, Somerset", latitude: 50.950196, longitude: -2.610720, storehours: "Mon-Sat: 9:00am - 7:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 1935 411000", website: "https://www.tesco.co.uk"),
        Store(name: "Sainsbury's Sherborne", vicinity: "Ludborne Road, Sherborne, Dorset", latitude: 50.948560, longitude: -2.516950, storehours: "Mon-Wed: 8:00am - 8:00pm, Thu-Sat: 8:00am - 9:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 1935 814671", website: "https://stores.sainsburys.co.uk/2144/sherborne"),
        Store(name: "Co-op Sherbs", vicinity: "Westbridge Park, Sherborne, Dorset", latitude: 50.948133, longitude: -2.517402, storehours: "Everyday: 7:00am - 10:00pm", phoneNumber: "+44 1935 813591", website: "https://www.coop.co.uk/store-finder/SK8%202PQ/110"),
        Store(name: "New World Victoria Park", vicinity: "2 College Hill, Freemans Bay, Auckland", latitude: -36.8485, longitude: 174.7573, storehours: "Everyday: 7:00am - 10:00pm", phoneNumber: "+64 9 378 7420", website: "https://www.newworld.co.nz"),
        Store(name: "Countdown Auckland City", vicinity: "76 Quay Street, Auckland CBD, Auckland", latitude: -36.845252, longitude: 174.772811, storehours: "Everyday: 7:00am - 10:00pm", phoneNumber: "+64 9 302 8665", website: "https://www.countdown.co.nz"),
        Store(name: "Pak’nSave Mt Albert", vicinity: "1167-1175 New North Road, Mt Albert, Auckland", latitude: -36.892702, longitude: 174.706145, storehours: "Everyday: 6:00am - 10:00pm", phoneNumber: "+64 9 846 7155", website: "https://www.paknsave.co.nz"),
        Store(name: "Four Square Ponsonby", vicinity: "254 Ponsonby Road, Ponsonby, Auckland", latitude: -36.8530, longitude: 174.7452, storehours: "Everyday: 7:00am - 9:00pm", phoneNumber: "+64 9 360 7777", website: "https://www.foursquare.co.nz"),
        Store(name: "Countdown Ponsonby", vicinity: "4 Williamson Avenue, Grey Lynn, Auckland", latitude: -36.858385, longitude: 174.748973, storehours: "Everyday: 7:00am - 10:00pm", phoneNumber: "+64 9 378 7592", website: "https://www.countdown.co.nz"),
        Store(name: "New World Howick", vicinity: "77 Union Road, Howick, Auckland 2014", latitude: -36.903890, longitude: 174.924999, storehours: "Everyday: 7:00am - 9:00pm", phoneNumber: "+64 9 534 9670", website: "https://www.newworld.co.nz"),
        Store(name: "Pak’nSave Botany", vicinity: "501 Ti Rakau Drive, Botany Downs, Auckland", latitude: -36.930635, longitude: 174.913218, storehours: "Everyday: 6:00am - 11:00pm", phoneNumber: "+64 9 273 3022", website: "https://www.paknsave.co.nz"),
        Store(name: "Countdown St Lukes", vicinity: "80 St Lukes Road, Mount Albert, Auckland", latitude: -36.88333, longitude: 174.734641, storehours: "Everyday: 7:00am - 10:00pm", phoneNumber: "+64 9 815 9997", website: "https://www.countdown.co.nz"),
        Store(name: "Asda Superstore Yeovil", vicinity: "Preston Road, Yeovil, Somerset", latitude: 50.943145, longitude: -2.668122, storehours: "Everyday: 7:00am - 10:00pm", phoneNumber: "+44 1935 476988", website: "https://storelocator.asda.com/store/yeovil"),
        Store(name: "Morrisons Yeovil", vicinity: "Lysander Road, Yeovil, Somerset", latitude: 50.9362, longitude: -2.6459, storehours: "Everyday: 7:00am - 10:00pm", phoneNumber: "+44 1935 474311", website: "https://my.morrisons.com/storefinder/336"),
        Store(name: "Lidl Yeovil", vicinity: "Lyde Road, Yeovil, Somerset", latitude: 50.946567, longitude: -2.611073, storehours: "Everyday: 8:00am - 10:00pm", phoneNumber: "+44 370 444 1234", website: "https://www.lidl.co.uk"),
        Store(name: "Sainsbury’s Local Sherborne", vicinity: "Cheap Street, Sherborne, Dorset", latitude: 50.9460, longitude: -2.5170, storehours: "Everyday: 7:00am - 11:00pm", phoneNumber: "+44 1935 817700", website: "https://stores.sainsburys.co.uk/2016/sherborne-local"),
        Store(name: "Co-op Food Sherborne", vicinity: "Westbridge Park, Sherborne, Dorset", latitude: 50.9481, longitude: -2.5174, storehours: "Everyday: 7:00am -10:00pm", phoneNumber: "+44 1935 813591", website: "https://www.coop.co.uk/store-finder/SK8%202PQ/110"),
        Store(name: "Asda Gillingham Superstore", vicinity: "Station Road, Gillingham, Dorset", latitude: 51.0372, longitude: -2.2765, storehours: "Everyday: 7:00am-11:00pm", phoneNumber: "+44 1747 822933", website: "https://storelocator.asda.com/store/gillingham-dorset"),
        Store(name: "Waitrose & Partners Gillingham", vicinity: "Le Neubourg Way, Gillingham, Dorset", latitude: 51.0380, longitude: -2.2750, storehours: "Everyday: 8:00am - 8:00pm", phoneNumber: "+44 1747 822932", website: "https://www.waitrose.com/content/waitrose/en/bf_home/bf/201.html"),
        Store(name: "Co-op Food Mere", vicinity: "The Square, Mere, Wiltshire", latitude: 51.0900, longitude: -2.2665, storehours: "Everyday: 7:00am - 10:00pm", phoneNumber: "+44 1747 860219", website: "https://www.coop.co.uk/store-finder/SP3%206JP/01212"),
        Store(name: "Chemist Warehouse Auckland CBD", vicinity: "246 Queen Street, Auckland CBD, Auckland", latitude: -36.8491, longitude: 174.7645, storehours: "Every day: 8:00am - 9:00pm", phoneNumber: "+64 9 309 5744", website: "https://www.chemistwarehouse.co.nz/"),
        Store(name: "Chemist Warehouse Newmarket", vicinity: "60 Broadway, Newmarket, Auckland", latitude: -36.8701, longitude: 174.7777, storehours: "Every day: 8:00am - 9:00pm", phoneNumber: "+64 9 522 2775", website: "https://www.chemistwarehouse.co.nz/"),
        Store(name: "Life Pharmacy Queen Street", vicinity: "175 Queen Street, Auckland CBD, Auckland", latitude: -36.8486, longitude: 174.7655, storehours: "Mon-Fri: 8:00am - 6:00pm, Sat-Sun: 10:00am - 5:00pm", phoneNumber: "+64 9 379 7310", website: "https://www.lifepharmacy.co.nz/"),
        Store(name: "Unichem Auckland Pharmacy", vicinity: "35 Victoria Street West, Auckland CBD, Auckland", latitude: -36.8475, longitude: 174.7643, storehours: "Mon-Fri: 8:00am - 6:00pm, Sat: 9:00am - 4:00pm, Sun: Closed", phoneNumber: "+64 9 377 0298", website: "https://www.unichem.co.nz/"),
        Store(name: "Pharmacy 277 Newmarket", vicinity: "277 Broadway, Newmarket, Auckland", latitude: -36.8695, longitude: 174.7772, storehours: "Every day: 9:00am - 6:00pm", phoneNumber: "+64 9 524 8866", website: "https://www.unichem.co.nz/store/pharmacy-277"),
        Store(name: "Boots Yeovil Middle Street", vicinity: "37 Middle Street, Yeovil, Somerset", latitude: 50.9412, longitude: -2.6309, storehours: "Mon-Sat: 8:30am - 5:30pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 1935 424392", website: "https://www.boots.com"),
        Store(name: "Marks & Spencer Yeovil", vicinity: "5 Middle Street, Yeovil, Somerset BA20 1LE", latitude: 50.94130, longitude: -2.63100, storehours: "Check in-store for current hours", phoneNumber: "+44 1935 423150", website: "https://www.marksandspencer.com/stores/yeovil-1630"),
        Store(name: "M&S Simply Food Beaconsfield West Yeovil BP", vicinity: "West Coker Road, Yeovil, Somerset BA22 9AA", latitude: 50.94320, longitude: -2.65500, storehours: "Check in-store for current hours", phoneNumber: "+44 333 014 8555", website: "https://www.marksandspencer.com/stores/west-yeovil-bp-922"),
        Store(name: "Superdrug Yeovil", vicinity: "4-6 Middle Street, Yeovil, Somerset", latitude: 50.9414, longitude: -2.6303, storehours: "Mon-Sat: 8:30am - 5:30pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 1935 476539", website: "https://www.superdrug.com/stores/103-yeovil"),
        Store(name: "LloydsPharmacy Yeovil", vicinity: "Mudford Road, Yeovil, Somerset", latitude: 50.9495, longitude: -2.6272, storehours: "Mon-Fri: 9:00am - 6:00pm, Sat: 9:00am - 1:00pm, Sun: Closed", phoneNumber: "+44 1935 474764", website: "https://www.lloydspharmacy.com/"),
        Store(name: "Abbey Pharmacy", vicinity: "Half Moon Street, Sherborne, Dorset", latitude: 50.9458, longitude: -2.5158, storehours: "Mon-Fri: 9:00am - 6:00pm, Sat: 9:00am - 5:00pm, Sun: Closed", phoneNumber: "+44 1935 812212", website: "https://www.abbeypharmacy.co.uk/"),
        Store(name: "Boots Gillingham", vicinity: "4 High Street, Gillingham, Dorset", latitude: 51.0377, longitude: -2.2743, storehours: "Mon-Sat: 9:00am - 5:30pm, Sun: Closed", phoneNumber: "+44 1747 822397", website: "https://www.boots.com"),
        Store(name: "LloydsPharmacy Gillingham", vicinity: "The Square, Gillingham, Dorset", latitude: 51.0381, longitude: -2.2749, storehours: "Mon-Fri: 9:00am - 6:00pm, Sat: 9:00am - 1:00pm, Sun: Closed", phoneNumber: "+44 1747 822105", website: "https://www.lloydspharmacy.com/"),
        Store(name: "Mere Pharmacy", vicinity: "The Square, Mere, Wiltshire", latitude: 51.0902, longitude: -2.2660, storehours: "Mon-Fri: 9:00am - 6:00pm, Sat: 9:00am - 1:00pm, Sun: Closed", phoneNumber: "+44 1747 860274", website: "https://www.merepharmacy.co.uk/"),
        Store(name: "Waitrose & Partners Gerrards Cross", vicinity: "31-33 Station Road, Gerrards Cross, SL9 8ES", latitude: 51.5885, longitude: -0.5543, storehours: "Mon-Fri: 8:00am - 9:00pm, Sat: 8:00am - 8:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 1753 888444", website: "https://www.waitrose.com/find-a-store/gerrards-cross"),
        Store(name: "Tesco Superstore Gerrards Cross", vicinity: "Packhorse Road, Gerrards Cross, SL9 8ER", latitude: 51.5880, longitude: -0.5540, storehours: "Mon-Sat: 6:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 345 026 9640", website: "https://www.tesco.com/store-locator/gerrards-cross/packhorse-rd"),
        Store(name: "Marks & Spencer Gerrards Cross", vicinity: "10 Packhorse Road, Gerrards Cross, SL9 7QE", latitude: 51.5882, longitude: -0.5541, storehours: "Mon-Sat: 8:00am - 8:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 1753 891200", website: "https://www.marksandspencer.com/stores/gerrards-cross-10-packhorse-road"),
        Store(name: "Aldi Uxbridge", vicinity: "1 York Road, Uxbridge, UB8 1RN", latitude: 51.5465, longitude: -0.4793, storehours: "Mon-Sat: 8:00am - 10:00pm, Sun: 11:00am - 5:00pm", phoneNumber: "+44 800 042 0800", website: "https://www.aldi.co.uk/store/s-uk-E0516"),
        Store(name: "Waitrose & Partners Beaconsfield", vicinity: "40 Penn Road, Beaconsfield, HP9 2PW", latitude: 51.6114, longitude: -0.6442, storehours: "Mon-Fri: 7:30am - 9:00pm, Sat: 7:30am - 8:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 1494 674440", website: "https://www.waitrose.com/find-a-store/beaconsfield"),
        Store(name: "Tesco Superstore Amersham", vicinity: "London Road West, Amersham, HP7 0HA", latitude: 51.6740, longitude: -0.6075, storehours: "Mon-Sat: 6:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 345 677 9380", website: "https://www.tesco.com/store-locator/amersham/london-rd-west"),
        Store(name: "Marks & Spencer Simply Food Amersham", vicinity: "Sycamore Road, Amersham, HP6 5DR", latitude: 51.6761, longitude: -0.6072, storehours: "Mon-Sat: 8:00am - 8:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 1494 722200", website: "https://www.marksandspencer.com/stores/amersham-simply-food-0005"),
        Store(name: "Aldi Slough", vicinity: "Bath Road, Slough, SL1 5PS", latitude: 51.5125, longitude: -0.6215, storehours: "Mon-Sat: 8:00am - 10:00pm, Sun: 11:00am - 5:00pm", phoneNumber: "+44 800 042 0800", website: "https://www.aldi.co.uk/store/s-uk-E0517"),
        Store(name: "Waitrose & Partners Rickmansworth", vicinity: "138 High Street, Rickmansworth, WD3 1AB", latitude: 51.6398, longitude: -0.4732, storehours: "Mon-Fri: 7:30am - 9:00pm, Sat: 7:30am - 8:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 1923 775586", website: "https://www.waitrose.com/find-a-store/rickmansworth"),
        Store(name: "Tesco Superstore Slough", vicinity: "Brunel Way, Slough, SL1 1XW", latitude: 51.5091, longitude: -0.5918, storehours: "Mon-Sat: 6:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 345 677 9381", website: "https://www.tesco.com/store-locator/slough/brunel-way"),
        Store(name: "New World Whitianga", vicinity: "1 Joan Gaskell Drive, Whitianga 3510", latitude: -36.8310, longitude: 175.7000, storehours: "Mon-Sun: 7:00am - 9:00pm", phoneNumber: "+64 7 867 1900", website: "https://www.newworld.co.nz/upper-north-island/waikato/whitianga"),
        Store(name: "Countdown Whitianga", vicinity: "1 Joan Gaskell Drive, Whitianga 3510", latitude: -36.8310, longitude: 175.7000, storehours: "Mon-Sun: 7:00am - 9:00pm", phoneNumber: "+64 7 866 4099", website: "https://www.countdown.co.nz/stores/whitianga"),
        Store(name: "Four Square Whitianga", vicinity: "66 Albert Street, Whitianga 3510", latitude: -36.8310, longitude: 175.7000, storehours: "Mon-Sun: 7:00am - 8:00pm", phoneNumber: "+64 7 866 5723", website: "https://www.foursquare.co.nz/upper-north-island/waikato/whitianga"),
        Store(name: "The Warehouse Whitianga", vicinity: "1 Joan Gaskell Drive, Whitianga 3510", latitude: -36.8310, longitude: 175.7000, storehours: "Mon-Sun: 7:00am - 9:00pm", phoneNumber: "+64 7 867 1900", website: "https://www.thewarehouse.co.nz/upper-north-island/waikato/whitianga"),
        Store(name: "Sainsbury’s Sherborne",vicinity: "Ludborne Road, Sherborne, Dorset DT9 3NY",latitude: 50.94856, longitude: -2.51695, storehours: "Mon–Sat: 8:00am – 9:00pm, Sun: 10:00am – 4:00pm", phoneNumber: "+44 1935 814671", website: "https://stores.sainsburys.co.uk/2144/sherborne"),
        Store(name: "Waitrose & Partners Sherborne", vicinity: "Cheap Street, Sherborne, Dorset DT9 3AA", latitude: 50.94660, longitude: -2.51650, storehours: "Mon–Sat: 8:00am – 8:00pm, Sun: 10:00am – 4:00pm", phoneNumber: "+44 1935 816775", website: "https://www.waitrose.com/find-a-store/sherborne"),
        Store(name: "Boots Sherborne", vicinity: "50 Cheap Street, Sherborne, Dorset DT9 3BJ", latitude: 50.94650, longitude: -2.51660,
            storehours: "Mon–Sat: 9:00am – 5:30pm, Sun: Closed", phoneNumber: "+44 1935 812425", website: "https://www.boots.com/stores/2001-sherborne-cheap-street"),
        Store(name: "Tesco Extra Yeovil", vicinity: "Queensway Place, Yeovil, Somerset BA20 1DL", latitude: 50.94140, longitude: -2.63250, storehours: "Mon–Sun: 6:00am – Midnight", phoneNumber: "+44 1935 411111", website: "https://www.tesco.com/store-locator/yeovil/extra"),

        Store(
            name: "Asda Superstore Yeovil",
            vicinity: "Preston Road, Yeovil, Somerset BA20 2DQ",
            latitude: 50.94750,
            longitude: -2.65760,
            storehours: "Mon–Sun: 7:00am – 10:00pm",
            phoneNumber: "+44 1935 476988",
            website: "https://storelocator.asda.com/store/yeovil"
        ),

        Store(
            name: "Lidl Yeovil",
            vicinity: "Lyde Road, Yeovil, Somerset BA20 2AJ",
            latitude: 50.94880,
            longitude: -2.61890,
            storehours: "Mon–Sun: 8:00am – 10:00pm",
            phoneNumber: "+44 370 444 1234",
            website: "https://www.lidl.co.uk/store-finder"
        ),

        Store(
            name: "Aldi Yeovil",
            vicinity: "Western Avenue, Yeovil, Somerset BA20 2XP",
            latitude: 50.94410,
            longitude: -2.65020,
            storehours: "Mon–Sat: 8:00am – 10:00pm, Sun: 10:00am – 4:00pm",
            phoneNumber: "+44 800 042 0800",
            website: "https://www.aldi.co.uk"
        ),

        Store(
            name: "Boots Yeovil Middle Street",
            vicinity: "37 Middle Street, Yeovil, Somerset BA20 1LZ",
            latitude: 50.94120,
            longitude: -2.63090,
            storehours: "Mon–Sat: 8:30am – 5:30pm, Sun: 10:00am – 4:00pm",
            phoneNumber: "+44 1935 424392",
            website: "https://www.boots.com/stores/1995-yeovil-middle-street"
        ),

        Store(
            name: "Holland & Barrett Yeovil",
            vicinity: "Quedam Shopping Centre, Yeovil, Somerset BA20 1EP",
            latitude: 50.94180,
            longitude: -2.63210,
            storehours: "Mon–Sat: 9:00am – 5:30pm, Sun: 10:30am – 4:30pm",
            phoneNumber: "+44 1935 428912",
            website: "https://www.hollandandbarrett.com/store-finder/yeovil"
        ),
        Store(
            name: "Tesco Dorchester Superstore",
            vicinity: "Thomas Hardy Retail Park, Dorchester, Dorset DT1 2YR",
            latitude: 50.71790,
            longitude: -2.44020,
            storehours: "Mon–Sat: 6:00am – 11:00pm, Sun: 10:00am – 4:00pm",
            phoneNumber: "+44 345 677 9455",
            website: "https://www.tesco.com/store-locator/dorchester"
        ),

        Store(
            name: "Sainsbury’s Dorchester",
            vicinity: "Bridport Road, Dorchester, Dorset DT1 1UX",
            latitude: 50.71630,
            longitude: -2.45190,
            storehours: "Mon–Sat: 7:00am – 10:00pm, Sun: 10:00am – 4:00pm",
            phoneNumber: "+44 1305 260400",
            website: "https://stores.sainsburys.co.uk/0873/dorchester"
        ),

        Store(
            name: "Waitrose & Partners Dorchester",
            vicinity: "Queen Mother Square, Poundbury, Dorchester DT1 3BW",
            latitude: 50.71690,
            longitude: -2.45530,
            storehours: "Mon–Sat: 8:00am – 8:00pm, Sun: 10:00am – 4:00pm",
            phoneNumber: "+44 1305 259300",
            website: "https://www.waitrose.com/find-a-store/dorchester"
        ),

        Store(
            name: "Boots Dorchester",
            vicinity: "South Street, Dorchester, Dorset DT1 1DE",
            latitude: 50.71580,
            longitude: -2.43790,
            storehours: "Mon–Sat: 9:00am – 5:30pm, Sun: Closed",
            phoneNumber: "+44 1305 250467",
            website: "https://www.boots.com/stores/2028-dorchester-south-street"
        ),
        Store(name: "Marks & Spencer Dorchester", vicinity: "48 South Street, Dorchester, Dorset DT1 1DQ", latitude: 50.71590, longitude: -2.43780, storehours: "Check in-store for current hours", phoneNumber: "+44 1305 263065", website: "https://www.marksandspencer.com/gp/store-locator"),

        Store(name: "Marks & Spencer Taunton", vicinity: "The County, East Street, Taunton, Somerset TA1 3LU", latitude: 51.01490, longitude: -3.10293, storehours: "Check in-store for current hours", phoneNumber: "+44 1823 288051", website: "https://www.marksandspencer.com/stores/taunton-6415"),
        Store(
            name: "Holland & Barrett Dorchester",
            vicinity: "South Street, Dorchester, Dorset DT1 1BY",
            latitude: 50.71600,
            longitude: -2.43820,
            storehours: "Mon–Sat: 9:00am – 5:30pm, Sun: Closed",
            phoneNumber: "+44 1305 266941",
            website: "https://www.hollandandbarrett.com/store-finder/dorchester"
        ),
        // New World (for online lookups)
        Store(name: "New World Metro Auckland", vicinity: "125 Queen Street, Auckland Central, Auckland, 1010", latitude: -36.846405, longitude: 174.765935, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Newmarket", vicinity: "42 Nuffield Street, Newmarket, Auckland, 1023", latitude: -36.8709201, longitude: 174.778261, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Remuera", vicinity: "10 Clonbern Road, Remuera, Auckland, 1050", latitude: -36.88171, longitude: 174.79751, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Eastridge", vicinity: "209 Kepa Road, Mission Bay, Auckland, 1071", latitude: -36.861179, longitude: 174.82901, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Stonefields", vicinity: "100 Lunn Avenue, Mt Wellington, Auckland, 1072", latitude: -36.890274, longitude: 174.831971, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Point Chevalier", vicinity: "1132 Great North Road, Point Chevalier, Auckland, 1022", latitude: -36.8699276, longitude: 174.7126578, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Mt Albert", vicinity: "1 Alberton Avenue, Mt Albert, Auckland, 1025", latitude: -36.880146, longitude: 174.72622, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Mt Roskill", vicinity: "53 May Road, Mt Roskill, Auckland, 1041", latitude: -36.908622, longitude: 174.734362, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World New Lynn", vicinity: "2-6 Crown Lynn Place, New Lynn, Auckland, 0600", latitude: -36.910865, longitude: 174.685569, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Green Bay", vicinity: "64 Godley Road, Green Bay, Auckland, 0604", latitude: -36.93074, longitude: 174.679184, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Hobsonville", vicinity: "120 Hobsonville Road, Hobsonville, Auckland, 0618", latitude: -36.79915, longitude: 174.64505, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Birkenhead", vicinity: "180 Mokoia Road, Chatswood, Auckland, 0626", latitude: -36.811428, longitude: 174.711486, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Devonport", vicinity: "35 Bartley Terrace, Devonport, Auckland, 0624", latitude: -36.82951, longitude: 174.796193, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Shore City", vicinity: "52-56 Anzac Street, Takapuna, Auckland, 0622", latitude: -36.78756, longitude: 174.77005, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Milford", vicinity: "141 Kitchener Road, Milford, Auckland, 0620", latitude: -36.772298, longitude: 174.764805, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Albany", vicinity: "219 Don McKinnon Drive, Albany, Auckland, 0632", latitude: -36.728207, longitude: 174.710519, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Browns Bay", vicinity: "2 Inverness Road, Browns Bay, Auckland, 0630", latitude: -36.715961, longitude: 174.747287, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Long Bay", vicinity: "55B Glenvar Ridge Road, Long Bay, Auckland, 0630", latitude: -36.684964, longitude: 174.73973, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Kumeu", vicinity: "108-110 Main Road, Kumeu, Auckland, 0810", latitude: -36.774933, longitude: 174.553672, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Whangaparaoa", vicinity: "580 Whangaparaoa Road, Stanmore Bay, Whangaparaoa, 0932", latitude: -36.628789, longitude: 174.732596, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Warkworth", vicinity: "6 Percy Street, Warkworth, 0910", latitude: -36.398709, longitude: 174.666795, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Botany", vicinity: "588 Chapel Road, East Tamaki, Auckland, 2013", latitude: -36.933874, longitude: 174.911485, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Ormiston", vicinity: "240 Ormiston Road, Ormiston, Auckland, 2019", latitude: -36.9647262, longitude: 174.912703, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Papatoetoe", vicinity: "65 St Georges Street, Papatoetoe, Auckland, 2025", latitude: -36.9802, longitude: 174.853287, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Southmall", vicinity: "187 Great South Road, Manurewa, Auckland, 2102", latitude: -37.02246, longitude: 174.89719, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Papakura", vicinity: "29-31 East Street, Auckland, 2110", latitude: -37.064268, longitude: 174.941101, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "New World Pukekohe", vicinity: "17 Paerata Road, Pukekohe, Auckland, 2120", latitude: -37.18988, longitude: 174.90306, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.newworld.co.nz"),
        // Woolworths / Countdown (Auckland additions)
        Store(name: "Metro Auckland Victoria Street West", vicinity: "19-25 Victoria Street Auckland Auckland 1010", latitude: -36.8480, longitude: 174.7638, storehours: "Mon-Sun: 7:00am - 8:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Metro Albert Street Woolworths", vicinity: "AMP Centre, Ground Floor, Auckland Auckland 1010", latitude: -36.8476, longitude: 174.7633, storehours: "Mon-Fri: 8:00am - 7:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Mount Eden Woolworths", vicinity: "Cnr Valley & Dominion Roads, Mt Eden, Auckland 1024", latitude: -36.8830, longitude: 174.7467, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Grey Lynn Woolworths", vicinity: "271 Richmond Road, Grey Lynn, Auckland 1022", latitude: -36.854227, longitude: 174.731543, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Greenlane Woolworths", vicinity: "326 Great South Road, Greenlane, Auckland 1051", latitude: -36.88932, longitude: 174.79366, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Onehunga Woolworths", vicinity: "Cnr Church Street & Selwyn Street, Onehunga, Auckland 1061", latitude: -36.9250, longitude: 174.7834, storehours: "Mon-Sun: 8:00am - 9:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Three Kings Woolworths", vicinity: "532 Mount Albert Road, Three Kings, Auckland 1042", latitude: -36.9130, longitude: 174.7464, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Pt Chevalier Woolworths", vicinity: "13 Pt Chevalier Road, Point Chevalier, Auckland 1022", latitude: -36.8690, longitude: 174.7097, storehours: "Mon-Sun: 8:00am - 9:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Birkenhead Woolworths", vicinity: "Cnr Highbury Pass & Birkenhead Avenue, Birkenhead, Auckland 0626", latitude: -36.8097, longitude: 174.7244, storehours: "Mon-Sun: 7:00am - 9:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Milford Woolworths", vicinity: "Milford Shopping Centre, Milford Road, Milford, Auckland 0620", latitude: -36.7715, longitude: 174.7649, storehours: "Mon-Sun: 7:00am - 9:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Takapuna Woolworths", vicinity: "Barry's Point Road, Takapuna, Auckland 0622", latitude: -36.7912, longitude: 174.7698, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Waiata Shores Woolworths", vicinity: "2 Periko Way, Takanini, Auckland 2112", latitude: -37.0336, longitude: 174.9047, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Papakura Woolworths", vicinity: "2 Averill Street, Papakura, Auckland 2110", latitude: -37.0648, longitude: 174.9440, storehours: "Mon-Sun: 7:00am - 9:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Lynnmall Woolworths", vicinity: "Lynnmall Shopping Centre, Great North Road, New Lynn, Auckland 0600", latitude: -36.9098, longitude: 174.6841, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),

        // PAK'nSAVE (Auckland additions)
        Store(name: "Pak’nSave Wairau Road", vicinity: "30-60 Wairau Road, Glenfield, Auckland 0627", latitude: -36.778922, longitude: 174.74407, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 441 0190", website: "https://www.paknsave.co.nz"),
        Store(name: "Pak’nSave Glen Innes", vicinity: "182 Apirana Avenue, Glen Innes, Auckland 1072", latitude: -36.8781, longitude: 174.8565, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 528 4885", website: "https://www.paknsave.co.nz"),
        Store(name: "Pak’nSave Silverdale", vicinity: "20 Hibiscus Coast Highway, Silverdale, Auckland 0993", latitude: -36.6235, longitude: 174.6790, storehours: "Mon-Sun: 8:00am - 10:00pm", phoneNumber: "+64 9 421 9160", website: "https://www.paknsave.co.nz"),

        // Chemist Warehouse (Auckland additions)
        Store(name: "Chemist Warehouse Auckland Lower Queen Street", vicinity: "1A/155 Queen Street, Auckland CBD, Auckland 1010", latitude: -36.8478, longitude: 174.7650, storehours: "Every day: 8:00am - 9:00pm", phoneNumber: "+64 9 941 4911", website: "https://www.chemistwarehouse.co.nz"),
        Store(name: "Chemist Warehouse Auckland Victoria Street", vicinity: "25 Victoria Street West, Auckland CBD, Auckland 1010", latitude: -36.8480, longitude: 174.7640, storehours: "Every day: 7:30am - 8:00pm", phoneNumber: "+64 9 872 5500", website: "https://www.chemistwarehouse.co.nz"),
        Store(name: "Chemist Warehouse Henderson", vicinity: "10-12 Ratanui Street, Henderson, Auckland 0612", latitude: -36.8794, longitude: 174.6298, storehours: "Every day: 8:30am - 7:00pm", phoneNumber: "+64 9 872 6730", website: "https://www.chemistwarehouse.co.nz"),
        Store(name: "Chemist Warehouse Flat Bush", vicinity: "Botany Junction Shopping Centre, 277 Te Irirangi Drive, Flat Bush, Auckland 2019", latitude: -36.9647, longitude: 174.8919, storehours: "Every day: 8:00am - 9:00pm", phoneNumber: "+64 9 941 4916", website: "https://www.chemistwarehouse.co.nz"),
        Store(name: "Chemist Warehouse Birkenhead", vicinity: "Highbury Shopping Centre, Cnr Highbury Bypass & Birkenhead Avenue, Birkenhead, Auckland", latitude: -36.8111, longitude: 174.7232, storehours: "Every day: 9:00am - 7:00pm", phoneNumber: "+64 9 941 4924", website: "https://www.chemistwarehouse.co.nz"),
        Store(name: "Chemist Warehouse Wairau Valley", vicinity: "231 Archers Road, Wairau Valley, Auckland 0627", latitude: -36.7751, longitude: 174.7310, storehours: "Every day: 8:00am - 8:00pm", phoneNumber: "+64 9 941 4927", website: "https://www.chemistwarehouse.co.nz"),
        Store(name: "Chemist Warehouse Highland Park", vicinity: "505 Pakuranga Road, Highland Park, Auckland 2143", latitude: -36.9054, longitude: 174.9064, storehours: "Every day: 8:00am - 9:00pm", phoneNumber: "+64 9 886 0740", website: "https://www.chemistwarehouse.co.nz"),
        Store(name: "Chemist Warehouse Albany", vicinity: "Albany Mega Centre, 140 Don McKinnon Drive, Albany, Auckland 0632", latitude: -36.7282, longitude: 174.6967, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.chemistwarehouse.co.nz"),
        Store(name: "Chemist Warehouse Silverdale", vicinity: "61 Silverdale Street, Silverdale, Auckland 0932", latitude: -36.6179, longitude: 174.6817, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.chemistwarehouse.co.nz"),
        Store(name: "Chemist Warehouse Ormiston", vicinity: "Shop R11, Ormiston Town Centre, 240 Ormiston Road, Flat Bush, Auckland 2016", latitude: -36.9647, longitude: 174.9127, storehours: "Every day: 8:30am - 9:00pm", phoneNumber: "+64 9 871 7618", website: "https://www.chemistwarehouse.co.nz"),
        Store(name: "Chemist Warehouse Hunters Plaza", vicinity: "217 Great South Road, Papatoetoe, Auckland 2025", latitude: -36.9778, longitude: 174.8500, storehours: "Every day: 8:00am - 8:00pm", phoneNumber: "+64 9 941 4922", website: "https://www.chemistwarehouse.co.nz"),
        Store(name: "Chemist Warehouse Onehunga", vicinity: "100 Church Street, Onehunga, Auckland 1061", latitude: -36.9228, longitude: 174.7850, storehours: "Check in-store for current hours", phoneNumber: "+64 9 941 4921", website: "https://www.chemistwarehouse.co.nz"),
        Store(name: "Chemist Warehouse Westgate", vicinity: "32 Maki Street, Westgate, Auckland 0614", latitude: -36.8227, longitude: 174.6114, storehours: "Every day: 8:00am - 9:00pm", phoneNumber: "+64 9 941 4905", website: "https://www.chemistwarehouse.co.nz"),
        Store(name: "Costco Wholesale Westgate", vicinity: "2 Gunton Drive, Westgate, Auckland", latitude: -36.810852, longitude: 174.608372, storehours: "Mon-Fri: 10:00am - 8:30pm, Sat: 9:30am - 6:30pm, Sun: 10:00am - 6:00pm", phoneNumber: "+64 9 415 5000", website: "https://www.costco.co.nz"),
        Store(name: "Farro Epsom", vicinity: "446 Manukau Road, Epsom, Auckland", latitude: -36.89383, longitude: 174.775056, storehours: "Check in-store for current hours", phoneNumber: "+64 9 892 6330", website: "https://www.farro.co.nz"),
        Store(name: "Farro Fresh Grey Lynn", vicinity: "34 Westmoreland Street West, Grey Lynn, Auckland", latitude: -36.855621, longitude: 174.732843, storehours: "Check in-store for current hours", phoneNumber: "+64 9 360 0499", website: "http://www.farrofresh.co.nz/grey-lynn/"),
        Store(name: "Farro Fresh Kingsland", vicinity: "Milton Road, Kingsland, Auckland", latitude: -36.881662, longitude: 174.749492, storehours: "Mon-Sun: 8:00am - 7:30pm", phoneNumber: "", website: "https://www.farro.co.nz"),
        Store(name: "Farro Mt Wellington", vicinity: "Lunn Avenue, Mount Wellington, Auckland", latitude: -36.890972, longitude: 174.833956, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.farro.co.nz"),
        Store(name: "Farro North Shore", vicinity: "65 Constellation Drive, Auckland", latitude: -36.750726, longitude: 174.727966, storehours: "Mon-Sun: 8:30am - 6:30pm", phoneNumber: "+64 9 892 6307", website: "https://www.farro.co.nz/"),
        Store(name: "Farro Smales Farm", vicinity: "The Lane, Forrest Hill, Auckland", latitude: -36.783583, longitude: 174.753472, storehours: "Mon-Fri: 7:30am - 7:30pm, Sat-Sun: 8:00am - 7:00pm", phoneNumber: "+64 9 892 6394", website: "https://www.farro.co.nz"),
        Store(name: "Farro Ōrākei", vicinity: "Orakei Road, Ōrākei, Auckland", latitude: -36.863032, longitude: 174.80899, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.farro.co.nz"),
        Store(name: "Four Square Customs Street", vicinity: "Customs Street East, City Centre, Auckland", latitude: -36.844752, longitude: 174.767648, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.foursquare.co.nz"),
        Store(name: "Four Square Eden Terrace", vicinity: "New North Road, Eden Terrace, Auckland", latitude: -36.865899, longitude: 174.759858, storehours: "Mon-Sun: 7:00am - 8:00pm", phoneNumber: "", website: "https://www.foursquare.co.nz"),
        Store(name: "Four Square Onehunga", vicinity: "Onehunga Mall, Onehunga, Auckland", latitude: -36.918963, longitude: 174.784535, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.foursquare.co.nz"),
        Store(name: "Four Square Palm Beach (Waiheke)", vicinity: "Eden Terrace, Waiheke, Auckland", latitude: -36.792684, longitude: 175.079706, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.foursquare.co.nz"),
        Store(name: "Four Square Remuera", vicinity: "561 Remuera Road, Remuera, Auckland", latitude: -36.880685, longitude: 174.811872, storehours: "Mon-Sun: 7:00am - 9:00pm", phoneNumber: "", website: "https://www.foursquare.co.nz"),
        Store(name: "Four Square Snells Beach", vicinity: "Mahurangi East Road, Snells Beach, Auckland", latitude: -36.419133, longitude: 174.723446, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.foursquare.co.nz"),
        Store(name: "Four Square St Heliers", vicinity: "Saint Heliers Bay Road, Auckland", latitude: -36.850872, longitude: 174.857832, storehours: "Mon-Sun: 7:00am - 8:00pm", phoneNumber: "", website: "https://www.foursquare.co.nz"),
        Store(name: "FreshChoice Glen Eden", vicinity: "142 West Coast Road, Glen Eden, Auckland", latitude: -36.91124, longitude: 174.653855, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://freshchoice.co.nz"),
        Store(name: "FreshChoice Greenwoods Corner", vicinity: "Epsom, Auckland", latitude: -36.892838, longitude: 174.779615, storehours: "Mon-Sun: 6:30am - 9:00pm", phoneNumber: "", website: "https://www.freshchoice.co.nz"),
        Store(name: "FreshChoice Half Moon Bay", vicinity: "Ara Tai, Auckland", latitude: -36.881159, longitude: 174.899915, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.freshchoice.co.nz"),
        Store(name: "FreshChoice Mangere Bridge", vicinity: "36 Coronation Road, Auckland", latitude: -36.942551, longitude: 174.786792, storehours: "Mon-Sun: 6:00am - 9:00pm", phoneNumber: "", website: "https://www.freshchoice.co.nz"),
        Store(name: "FreshChoice Rānui", vicinity: "Swanson Road, Rānui, Auckland", latitude: -36.863727, longitude: 174.601451, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.freshchoice.co.nz"),
        Store(name: "FreshChoice Titirangi", vicinity: "429 Titirangi Road, Titirangi, Auckland", latitude: -36.937433, longitude: 174.656418, storehours: "Mon-Sun: 7:00am - 9:00pm", phoneNumber: "+64 9 817 6859", website: "https://titirangi.store.freshchoice.co.nz/"),
        Store(name: "FreshChoice Waimauku", vicinity: "State Highway 16, Waimauku, Auckland", latitude: -36.767877, longitude: 174.493663, storehours: "Mon-Sun: 7:00am - 9:00pm", phoneNumber: "", website: "https://www.freshchoice.co.nz"),
        Store(name: "FreshChoice Ōtāhuhu", vicinity: "33 Hall Avenue, Ōtāhuhu, Auckland", latitude: -36.94485, longitude: 174.842486, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.freshchoice.co.nz"),
        Store(name: "New World Waiuku", vicinity: "Waiuku, Auckland", latitude: -37.24978, longitude: 174.728345, storehours: "Mon-Sun: 7:00am - 9:00pm", phoneNumber: "+64 9 236 5050", website: "https://www.newworld.co.nz/upper-north-island/auckland/waiuku"),
        Store(name: "New World Ōrewa", vicinity: "11 Moana Avenue, Ōrewa, Ōrewa, Auckland", latitude: -36.586538, longitude: 174.693604, storehours: "Mon-Sun: 8:00am - 10:00pm", phoneNumber: "", website: "https://www.newworld.co.nz"),
        Store(name: "Pak’nSave Clendon", vicinity: "Robert Ross Place, Clendon Park, Auckland", latitude: -37.032476, longitude: 174.867427, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.paknsave.co.nz/upper-north-island/auckland/clendon"),
        Store(name: "Pak’nSave Henderson", vicinity: "8 Alderman Drive, Henderson, Auckland", latitude: -36.877114, longitude: 174.632488, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.paknsave.co.nz/upper-north-island/auckland/henderson"),
        Store(name: "Pak’nSave Highland Park", vicinity: "Pakuranga Road, Auckland", latitude: -36.89929, longitude: 174.906953, storehours: "Mon-Sun: 7:30am - 10:00pm", phoneNumber: "", website: "https://www.paknsave.co.nz"),
        Store(name: "Pak’nSave Manukau", vicinity: "Cavendish Drive, Manukau, Auckland", latitude: -36.987935, longitude: 174.880668, storehours: "Mon-Sun: 8:00am - 10:00pm", phoneNumber: "", website: "https://www.paknsave.co.nz/upper-north-island/auckland/manukau"),
        Store(name: "Pak’nSave Papakura", vicinity: "341 Great South Road, Takanini, Auckland", latitude: -37.053663, longitude: 174.930641, storehours: "Mon-Sun: 7:00am - 9:00pm", phoneNumber: "+64 9 295 0012", website: "https://www.paknsave.co.nz/upper-north-island/auckland/papakura"),
        Store(name: "Pak’nSave Pukekohe", vicinity: "Harris Street, Pukekohe, Auckland", latitude: -37.205253, longitude: 174.899614, storehours: "Mon-Sun: 8:00am - 9:00pm", phoneNumber: "", website: "https://www.paknsave.co.nz/upper-north-island/auckland/pukekohe"),
        Store(name: "Pak’nSave Warkworth", vicinity: "Old State Highway 1, Warkworth, Auckland", latitude: -36.392177, longitude: 174.649476, storehours: "Mon-Sun: 8:00am - 9:00pm", phoneNumber: "+64 9 283 3985", website: "https://www.paknsave.co.nz/upper-north-island/auckland/warkworth"),
        Store(name: "SuperValue Clover Park", vicinity: "Dawson Road, Clover Park, Auckland", latitude: -36.976719, longitude: 174.897088, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.supervalue.co.nz"),
        Store(name: "SuperValue Panmure", vicinity: "88 Queens Road, Auckland", latitude: -36.89963, longitude: 174.854785, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.supervalue.co.nz"),
        Store(name: "SuperValue Takanini", vicinity: "Manuroa Road, Takanini, Auckland", latitude: -37.039227, longitude: 174.919353, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.supervalue.co.nz"),
        Store(name: "SuperValue Waiuku", vicinity: "Queen Street, Waiuku, Auckland", latitude: -37.251795, longitude: 174.730582, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.supervalue.co.nz"),
        Store(name: "Woolworths Auckland Airport", vicinity: "John Goulter Drive, Māngere-Ōtāhuhu, Auckland", latitude: -36.997496, longitude: 174.789029, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 255 9697", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Beachlands", vicinity: "Kouka Road, Beachlands, Auckland", latitude: -36.88981, longitude: 175.010371, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 536 5176", website: "https://www.woolworths.co.nz/store-finder/9177/beachlands/beachlands-countdown"),
        Store(name: "Woolworths Browns Bay", vicinity: "Anzac Road, Browns Bay, Auckland", latitude: -36.717455, longitude: 174.747287, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 476 5974", website: "https://www.countdown.co.nz/store-finder/9224/browns-bay/browns-bay-countdown"),
        Store(name: "Woolworths Greville Road", vicinity: "65 Greville Road, Pinehill, Auckland", latitude: -36.731787, longitude: 174.720739, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 478 2720", website: "https://www.woolworths.co.nz/store-finder/9171/pinehill/greville-road-woolworths"),
        Store(name: "Woolworths Halsey Street", vicinity: "Pakenham Street West, City Centre, Auckland", latitude: -36.843778, longitude: 174.757067, storehours: "Mon-Fri: 7:00am - 7:00pm, Sat, Sun: 8:00am - 6:00pm", phoneNumber: "+64 9 377 9146", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Hauraki Corner", vicinity: "Lake Road, Hauraki, Auckland", latitude: -36.796729, longitude: 174.77794, storehours: "Mon-Sun: 8:00am - 9:00pm", phoneNumber: "+64 9 255 9731", website: "https://www.woolworths.co.nz/store-finder/9060/belmont-hauraki/hauraki-corner-countdown"),
        Store(name: "Woolworths Helensville", vicinity: "43 Commercial Road, Helensville, Auckland", latitude: -36.67724, longitude: 174.451172, storehours: "Check in-store for current hours", phoneNumber: "+64 9 420 6509", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Henderson", vicinity: "Auckland", latitude: -36.880462, longitude: 174.632268, storehours: "Mon-Sun: 9:00am - 10:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Herne Bay", vicinity: "1 Kelmarna Avenue, Herne Bay, Auckland", latitude: -36.846614, longitude: 174.733446, storehours: "Mon-Sun: 7:00am - 9:00pm", phoneNumber: "+64 9 376 7279", website: "https://www.countdown.co.nz/store-finder/9249/herne-bay/metro-herne-bay"),
        Store(name: "Woolworths Highland Park", vicinity: "Highland Park Drive, Highland Park, Auckland", latitude: -36.899435, longitude: 174.908231, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Hobsonville", vicinity: "124 Hobsonville Road, Hobsonville, Auckland", latitude: -36.797636, longitude: 174.647791, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 416 7516", website: "https://www.woolworths.co.nz/store-finder/9551/hobsonville/hobsonville-woolworths"),
        Store(name: "Woolworths Howick", vicinity: "35 Cook Street, Howick, Auckland", latitude: -36.8961, longitude: 174.932618, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 535 9738", website: "http://Woolworths.co.nz"),
        Store(name: "Woolworths Kelston", vicinity: "West Coast Road, Kelston, Auckland", latitude: -36.909542, longitude: 174.663662, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Lincoln Road", vicinity: "Universal Drive, Te Atatū South, Auckland", latitude: -36.857297, longitude: 174.631681, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 835 3985", website: "https://www.woolworths.co.nz/store-finder/9038/henderson/lincoln-road-woolworths"),
        Store(name: "Woolworths Lynfield", vicinity: "570 Hillsborough Road, Lynfield, Auckland", latitude: -36.925372, longitude: 174.722968, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 626 0596", website: "https://www.woolworths.co.nz/store-finder/9140/lynfield/lynfield-woolworths"),
        Store(name: "Woolworths Mairangi Bay", vicinity: "Hastings Road, Mairangi Bay, Auckland", latitude: -36.739379, longitude: 174.752807, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 478 7402", website: "https://www.countdown.co.nz/store-finder/9248/mairangi-bay/mairangi-bay-countdown"),
        Store(name: "Woolworths Manurewa", vicinity: "Browns Road, Wiri, Auckland", latitude: -37.017468, longitude: 174.863967, storehours: "Mon-Sun: 10:00am - 10:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Meadowbank", vicinity: "/35 Saint Johns Road, Auckland", latitude: -36.876366, longitude: 174.828378, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Meadowlands", vicinity: "112 Whitford Road, Somerville, Auckland", latitude: -36.913498, longitude: 174.928834, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 537 8497", website: "https://www.woolworths.co.nz/"),
        Store(name: "Woolworths Mount Roskill", vicinity: "Stoddard Road, Wesley, Auckland", latitude: -36.904094, longitude: 174.726878, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Māngere East", vicinity: "Growers Lane, Māngere East, Auckland", latitude: -36.965774, longitude: 174.824097, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Māngere Town Centre", vicinity: "Waddon Place, Māngere, Auckland", latitude: -36.970369, longitude: 174.800736, storehours: "Mon-Sun: 7:00am - 9:00pm", phoneNumber: "+64 9 255 9670", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Northcote", vicinity: "Lake Road, Northcote, Auckland", latitude: -36.800216, longitude: 174.744979, storehours: "Mon-Sun: 8:00am - 8:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz/"),
        Store(name: "Woolworths Northwest", vicinity: "Fred Taylor Drive, Westgate, Auckland", latitude: -36.818703, longitude: 174.612137, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Pakuranga", vicinity: "Pakuranga, Auckland", latitude: -36.912987, longitude: 174.870989, storehours: "Check in-store for current hours", phoneNumber: "+64 9 570 1649", website: "https://www.woolworths.co.nz/store-finder/9204/pakuranga/pakuranga-woolworths"),
        Store(name: "Woolworths Papatoetoe", vicinity: "Great South Road, Auckland", latitude: -36.97069, longitude: 174.860672, storehours: "Mon-Sun: 8:00am - 9:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Pukekohe", vicinity: "Seddon Lane, Pukekohe, Auckland", latitude: -37.199567, longitude: 174.902217, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Pukekohe South", vicinity: "Svendsen Road, Pukekohe, Auckland", latitude: -37.21059, longitude: 174.912006, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Roselands Mall", vicinity: "Subway Road, Papakura, Auckland", latitude: -37.058956, longitude: 174.941178, storehours: "Mon-Sun: 8:00am - 9:00pm", phoneNumber: "+64 9 298 9413", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Silverdale", vicinity: "Central Boulevard, Silverdale, Auckland", latitude: -36.614001, longitude: 174.681075, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 421 9185", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths St Johns", vicinity: "Felton Mathew Avenue, Saint Johns, Auckland", latitude: -36.879504, longitude: 174.852199, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Sunnynook", vicinity: "15/120 Sunnynook Road, Auckland", latitude: -36.759099, longitude: 174.739727, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 410 8491", website: "https://www.woolworths.co.nz/store-finder/9197/sunnynook/sunnynook-woolworths"),
        Store(name: "Woolworths Takanini", vicinity: "Glenora Road, Takanini, Auckland", latitude: -37.047539, longitude: 174.927175, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 255 2408", website: "https://www.countdown.co.nz/store-finder/9202/takanini/takanini-countdown"),
        Store(name: "Woolworths Te Atatu South", vicinity: "Edmonton Road, Te Atatū South, Auckland", latitude: -36.865658, longitude: 174.64631, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 836 2582", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Waiheke Island (Ostend)", vicinity: "Belgium Street, Waiheke, Auckland", latitude: -36.796055, longitude: 175.045914, storehours: "Mon-Sun: 7:00am - 9:00pm", phoneNumber: "+64 9 372 8431", website: "https://www.woolworths.co.nz/store-finder/9030/ostend/waiheke-island-countdown"),
        Store(name: "Woolworths Warkworth", vicinity: "Mill Lane, Warkworth, Auckland", latitude: -36.399476, longitude: 174.663977, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Whangaparaoa", vicinity: "713 Whangaparaoa Road, Auckland", latitude: -36.636275, longitude: 174.746126, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+64 9 424 9222", website: "https://www.woolworths.co.nz"),
        Store(name: "Woolworths Ōrewa", vicinity: "5-11 Moenui Avenue, Ōrewa, Ōrewa, Auckland", latitude: -36.58832, longitude: 174.695056, storehours: "Check in-store for current hours", phoneNumber: "+64 9 421 9300", website: "https://www.woolworths.co.nz"),
        Store(name: "Aldi Amersham", vicinity: "Amersham", latitude: 51.663856, longitude: -0.60756, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.aldi.co.uk"),
        Store(name: "Aldi Gillingham", vicinity: "Gillingham", latitude: 51.028522, longitude: -2.256695, storehours: "Mon-Sat: 8:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.aldi.co.uk/store-finder/l/gillingham-dorset/park-farm/c478"),
        Store(name: "Aldi Windsor", vicinity: "Dedworth Road, Windsor", latitude: 51.479992, longitude: -0.658922, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.aldi.co.uk/store-finder/l/windsor/dedworth-road/c424"),
        Store(name: "Aldi Seaton", vicinity: "Underfleet Way, Seaton", latitude: 50.704794, longitude: -3.06914, storehours: "Mon-Sat: 7:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.aldi.co.uk/store-finder/l/seaton/the-underfleet/k084"),
        Store(name: "Aldi Slough 141 Farnham Road", vicinity: "141 Farnham Road, Slough", latitude: 51.522695, longitude: -0.616147, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.aldi.co.uk/store-finder/l/slough/141-farnham-road/c516"),
        Store(name: "Aldi Taunton", vicinity: "Chip Lane, Taunton", latitude: 51.023526, longitude: -3.110816, storehours: "Mon-Sat: 8:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.aldi.co.uk/store-finder/l/taunton/chip-lane/k088"),
        Store(name: "Aldi Taunton Bridgwater Road", vicinity: "Bridgwater Road, Taunton", latitude: 51.026604, longitude: -3.068293, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.aldi.co.uk/store-finder/l/taunton/bridgwater-road/k062"),
        Store(name: "Aldi Yeovil", vicinity: "Sherborne Road, Yeovil", latitude: 50.943092, longitude: -2.623064, storehours: "Mon-Sat: 8:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.aldi.co.uk/store-finder/l/yeovil/sherborne-road/c415"),
        Store(name: "Aldi West Drayton", vicinity: "141-161 High Street, West Drayton", latitude: 51.514562, longitude: -0.474268, storehours: "Mon-Sat: 8:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.aldi.co.uk/store-finder/l/west-drayton/high-street/k197"),
        Store(name: "Asda Hayes Superstore", vicinity: "Millington Road, Hayes", latitude: 51.500998, longitude: -0.425174, storehours: "Mon: 7:00am - Midnight, Tue-Fri: Midnight - Midnight, Sat: Midnight - 10:00pm, Sun: 11:00am - 5:00pm", phoneNumber: "", website: "https://storelocator.asda.com/london/hayes/millington-road"),
        Store(name: "Asda Slough", vicinity: "Telford Drive, Slough", latitude: 51.507277, longitude: -0.630185, storehours: "Mon-Wed: 7:00am - 10:00pm, Thu-Fri: 7:00am - Midnight, Sat: 7:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://storelocator.asda.com/south-east/slough/telford-drive"),
        Store(name: "Asda Taunton", vicinity: "Creechbarrow Road, Taunton", latitude: 51.022906, longitude: -3.083307, storehours: "Mon-Fri: 6:00am - Midnight, Sat: 6:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://storelocator.asda.com/south-west/taunton/creechbarrow-road"),
        Store(name: "Co-op Food Rickmansworth", vicinity: "189-191 Watford Road, Rickmansworth", latitude: 51.650193, longitude: -0.43545, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+441923 246014", website: "https://www.coop.co.uk/store-finder/WD3-3TL/189-191-watford-road"),
        Store(name: "Co-op Food Windsor", vicinity: "72 - 74 Arthur Road, Windsor", latitude: 51.482486, longitude: -0.615499, storehours: "Mon-Sun: 6:30am - 10:00pm", phoneNumber: "", website: "https://stores.southern.coop/berkshire/windsor/72-74-arthur-road.html"),
        Store(name: "Co-op Food Dorchester", vicinity: "8 Trinity Square, Dorchester", latitude: 50.713244, longitude: -2.438738, storehours: "Mon-Sat: 6:00am - 11:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/DT1-1TT/trinity-square"),
        Store(name: "Co-op Food Axminster", vicinity: "Lyme Street, Axminster", latitude: 50.782082, longitude: -2.997662, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/EX13-5AT/lyme-street"),
        Store(name: "Co-op Food Beaminster", vicinity: "23,24 The Square, Beaminster", latitude: 50.808834, longitude: -2.739409, storehours: "Mon-Sun: 7:00am - 11:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/DT8-3AU/23-the-square"),
        Store(name: "Co-op Food Bridport", vicinity: "Sea Road North, Bridport", latitude: 50.738431, longitude: -2.746204, storehours: "Mon-Sat: 6:00am - 11:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/DT6-4RR/sea-road-north"),
        Store(name: "Co-op Food Wincanton", vicinity: "Carrington Way, Wincanton", latitude: 51.057237, longitude: -2.40889, storehours: "Mon-Sat: 7:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/BA9-9JB/1-camelot-shopping-centre"),
        Store(name: "Co-op Food Castle Cary", vicinity: "Lower Woodcock Street, Castle Cary", latitude: 51.088142, longitude: -2.515284, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.coop.co.uk"),
        Store(name: "Co-op Food Gillingham", vicinity: "3-6 The Parade", latitude: 51.041643, longitude: -2.276319, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/SP8-4EH/5-6-lodbourne-green-parade"),
        Store(name: "Co-op Food Harefield", vicinity: "Rickmansworth Road, Uxbridge", latitude: 51.604886, longitude: -0.481957, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/UB9-6BU/rickmansworth-road"),
        Store(name: "Co-op Food Harlington", vicinity: "Harlington", latitude: 51.487593, longitude: -0.436119, storehours: "Mon-Sun: 7:00am - 11:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/UB3-5DS/222-224-high-street"),
        Store(name: "Co-op Food Hayes End", vicinity: "274-276 Kingshill Avenue, Hayes", latitude: 51.531969, longitude: -0.421337, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "+44 20 8842 1578", website: "https://www.coop.co.uk/store-finder/UB4-8BY/274-276-kingshill-avenue?utm_source=gmb&utm_medium=organic&utm_campaign=gmb-Hayes-Hayes"),
        Store(name: "Co-op Food Ickenham", vicinity: "17 Swakeleys Road, Uxbridge", latitude: 51.564544, longitude: -0.445056, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/UB10-8DF/17-swakeleys-road"),
        Store(name: "Co-op Food Iver", vicinity: "9 High Street, Iver", latitude: 51.51978, longitude: -0.504745, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.coop.co.uk"),
        Store(name: "Co-op Food Martock", vicinity: "North Street, Martock", latitude: 50.971354, longitude: -2.765882, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/TA12-6DL/the-martock-centre"),
        Store(name: "Co-op Food Slough", vicinity: "238-240 Trelawney Avenue, Slough", latitude: 51.501997, longitude: -0.554682, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.coop.co.uk"),
        Store(name: "Co-op Food Somerton", vicinity: "Brunel Shopping Precinct, Somerton", latitude: 51.054279, longitude: -2.730135, storehours: "Mon-Sat: 7:00am - 8:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/TA11-7PY/brunel-shopping-precinct"),
        Store(name: "Co-op Food South Petherton", vicinity: "4 St James's Street, South Petherton", latitude: 50.948608, longitude: -2.80786, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/TA13-5BS/4-st-james-street"),
        Store(name: "Co-op Food Stoke Poges", vicinity: "Bells Hill, Slough", latitude: 51.549041, longitude: -0.5852, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/SL2-4BY/bells-hill"),
        Store(name: "Co-op Food Stoke sub Hamdon", vicinity: "Stoke sub Hamdon", latitude: 50.953072, longitude: -2.729445, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/TA14-6UQ/115-montacute-road"),
        Store(name: "Co-op Food Sturminster Newton", vicinity: "Station Road", latitude: 50.92774, longitude: -2.303864, storehours: "Mon-Sat: 7:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://stores.southern.coop/dorset/sturminster-newton/lower-market-way.html"),
        Store(name: "Co-op Food Taunton", vicinity: "169 Cheddon Road, Taunton", latitude: 51.029856, longitude: -3.101517, storehours: "Mon-Sun: 7:00am - 11:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/TA2-7AH/169-cheddon-road"),
        Store(name: "Co-op Food Axminster West Street", vicinity: "West Street, Axminster", latitude: 50.780563, longitude: -2.999522, storehours: "Mon-Sat: 7:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/EX13-5PA/west-street"),
        Store(name: "Co-op Food Yeovil", vicinity: "Yeovil", latitude: 50.951287, longitude: -2.648076, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/BA21-3EG/72-stiby-road"),
        Store(name: "Co-op Food Yeovil Mudford Road", vicinity: "Yeovil Without", latitude: 50.957337, longitude: -2.62977, storehours: "Mon-Sun: 6:00am - 10:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/BA21-4LX/176-st-michaels-avenue"),
        Store(name: "Lidl Bridport", vicinity: "St Andrew's Road, Bridport", latitude: 50.739539, longitude: -2.744676, storehours: "Mon-Sat: 8:00am - 9:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.lidl.co.uk/s/en-GB/store-finder/bridport/dorset/st-andrews-road/"),
        Store(name: "Lidl Chard", vicinity: "Tapstone Road, Chard", latitude: 50.873653, longitude: -2.956612, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.lidl.co.uk/s/en-GB/store-finder/chard/tapstone-road/"),
        Store(name: "Lidl Cowley", vicinity: "137 Cowley Road, Uxbridge", latitude: 51.53523, longitude: -0.483669, storehours: "Mon-Sat: 8:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.lidl.co.uk/s/en-GB/store-finder/london/uxbridge/cowley-road-137/"),
        Store(name: "Lidl Crewkerne", vicinity: "George Lane, Crewkerne", latitude: 50.884361, longitude: -2.794725, storehours: "Mon-Sat: 8:00am - 9:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.lidl.co.uk/s/en-GB/store-finder/crewkerne/somerset/the-george-shopping-centre/"),
        Store(name: "Lidl Dorchester", vicinity: "1 The Grove", latitude: 50.718238, longitude: -2.44097, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.lidl.co.uk/s/en-GB/store-finder/dorchester/the-grove-1/"),
        Store(name: "Lidl Gillingham", vicinity: "School Lane, Gillingham", latitude: 51.037334, longitude: -2.271971, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.lidl.co.uk/s/en-GB/store-finder/gillingham/dorset/newbury/"),
        Store(name: "Lidl Hayes", vicinity: "1 Central Avenue, Hayes", latitude: 51.50864, longitude: -0.420099, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.lidl.co.uk/s/en-GB/store-finder/hayes/central-avenue/"),
        Store(name: "Lidl Bridgwater", vicinity: "Carnival Way, Bridgwater", latitude: 51.103652, longitude: -2.999668, storehours: "Mon-Sat: 8:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.lidl.co.uk/s/en-GB/store-finder/bridgwater/carnival-way-12/"),
        Store(name: "Lidl Slough 2 Twinches Lane", vicinity: "2 Twinches Lane, Slough", latitude: 51.512766, longitude: -0.622114, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.lidl.co.uk/s/en-GB/store-finder/slough/slough-retail-park-bath-road-unit-3a/"),
        Store(name: "Lidl Slough 360 Farnham Road", vicinity: "360 Farnham Road, Slough", latitude: 51.526952, longitude: -0.615612, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.lidl.co.uk/s/en-GB/store-finder/slough/farnham-road-360-362/"),
        Store(name: "Lidl Taunton Castle Street", vicinity: "Castle Street, Taunton", latitude: 51.014713, longitude: -3.110778, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.lidl.co.uk/s/en-GB/store-finder/taunton/castle-street/"),
        Store(name: "Lidl Taunton Roman Road", vicinity: "Roman Road, Taunton", latitude: 51.019031, longitude: -3.082784, storehours: "Mon-Sat: 7:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.lidl.co.uk/s/en-GB/store-finder/taunton/roman-road/"),
        Store(name: "Lidl Uxbridge", vicinity: "High Street, Uxbridge", latitude: 51.545778, longitude: -0.476606, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.lidl.co.uk"),
        Store(name: "Lidl Wincanton", vicinity: "Southgate Road, Wincanton", latitude: 51.050461, longitude: -2.415704, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.lidl.co.uk/s/en-GB/store-finder/wincanton/southgate-road/"),
        Store(name: "Lidl Yeovil West Hendford", vicinity: "West Hendford, Yeovil", latitude: 50.936852, longitude: -2.642377, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.lidl.co.uk/s/en-GB/store-finder/yeovil/west-henford/"),
        Store(name: "M&S Foodhall Chalfont St Peter", vicinity: "High Street, Gerrards Cross", latitude: 51.60713, longitude: -0.555454, storehours: "Mon-Sat: 8:00am - 8:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.marksandspencer.com/stores/chalfont-st-peter-foodhall-776"),
        Store(name: "M&S Simply Food Beaconsfield", vicinity: "9-10 Station Road, Beaconsfield", latitude: 51.609665, longitude: -0.645389, storehours: "Mon-Sat: 8:00am - 8:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.marksandspencer.com/stores/beaconsfield-simply-food-8840"),
        Store(name: "Morrisons Bridport", vicinity: "West Bay Road, Bridport", latitude: 50.726117, longitude: -2.756247, storehours: "Mon-Sat: 7:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://my.morrisons.com/storefinder/347/bridport"),
        Store(name: "Morrisons Taunton", vicinity: "Deller's Wharf, Taunton", latitude: 51.019063, longitude: -3.104015, storehours: "Mon-Sat: 7:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://my.morrisons.com/storefinder/335/taunton"),
        Store(name: "Morrisons Watford", vicinity: "Ascot Road, Watford", latitude: 51.648155, longitude: -0.423371, storehours: "Mon-Sat: 7:00am - 11:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 1923 700695", website: "https://my.morrisons.com/storefinder/586/watford"),
        Store(name: "Morrisons Wincanton", vicinity: "Southgate Road, Wincanton", latitude: 51.049177, longitude: -2.416737, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://my.morrisons.com/storefinder/342/wincanton"),
        Store(name: "Sainsbury's Beaconsfield", vicinity: "Maxwell Road, Beaconsfield", latitude: 51.609738, longitude: -0.643055, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://stores.sainsburys.co.uk/0739/beaconsfield"),
        Store(name: "Sainsbury's Burnham", vicinity: "Lake End Road, Maidenhead", latitude: 51.520355, longitude: -0.669194, storehours: "Mon-Sat: 6:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 1628 661529", website: "https://stores.sainsburys.co.uk/0638/taplow"),
        Store(name: "Sainsbury's Chard", vicinity: "Holyrood Street, Chard", latitude: 50.871562, longitude: -2.966027, storehours: "Mon-Fri: 7:00am - 9:00pm, Sat: 7:00am - 8:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://stores.sainsburys.co.uk/2210/chard"),
        Store(name: "Sainsbury's Chesham", vicinity: "134-144 High Street, Chesham", latitude: 51.707461, longitude: -0.611945, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://stores.sainsburys.co.uk/2008/chesham"),
        Store(name: "Sainsbury's Slough", vicinity: "Uxbridge Road, Slough", latitude: 51.508109, longitude: -0.579145, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://stores.sainsburys.co.uk/2242/slough-uxbridge-road"),
        Store(name: "Sainsbury's Taunton Billet Street", vicinity: "Billet Street, Taunton", latitude: 51.013783, longitude: -3.099017, storehours: "Mon-Wed: 7:00am - 8:00pm, Thu-Sat: 7:00am - 9:00pm, Sun: 10:30am - 4:30pm", phoneNumber: "", website: "https://stores.sainsburys.co.uk/0655/taunton"),
        Store(name: "Sainsbury's Taunton Hankridge Farm", vicinity: "Hankridge Farm, Taunton", latitude: 51.021752, longitude: -3.061045, storehours: "Check in-store for current hours", phoneNumber: "+44 1823 443163", website: "https://stores.sainsburys.co.uk/0709/hankridge-farm"),
        Store(name: "Sainsbury's Uxbridge", vicinity: "York Road, Uxbridge", latitude: 51.548586, longitude: -0.474779, storehours: "Mon-Sat: 7:00am - 11:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://stores.sainsburys.co.uk/0603/uxbridge"),
        Store(name: "Shillingstone Co-op", vicinity: "Cookswell, Shillingstone", latitude: 50.90533, longitude: -2.253485, storehours: "Mon-Sun: 7:00am - 10:00pm", phoneNumber: "", website: "https://www.coop.co.uk/store-finder/DT11-0QZ/blandford-road"),
        Store(name: "Tesco Amersham", vicinity: "London Road, Amersham", latitude: 51.666203, longitude: -0.611452, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.tesco.com/store-locator/amersham/19-london-road-west"),
        Store(name: "Tesco Axminster", vicinity: "Shand Park, Axminster", latitude: 50.782361, longitude: -3.001278, storehours: "Mon-Sat: 8:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.tesco.com/store-locator/axminster/shand-park"),
        Store(name: "Tesco Chard", vicinity: "Tapstone Road, Chard", latitude: 50.874115, longitude: -2.954247, storehours: "Mon-Sat: 8:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.tesco.com/store-locator/chard/tapstone-rd"),
        Store(name: "Tesco High Wycombe", vicinity: "London Road, High Wycombe", latitude: 51.604978, longitude: -0.692609, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.tesco.com/store-locator/high-wycombe/london-rd"),
        Store(name: "Tesco Dorchester", vicinity: "Weymouth Avenue, Dorchester", latitude: 50.701684, longitude: -2.443996, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.tesco.com/store-locator/dorchester/weymouth-ave"),
        Store(name: "Tesco Ilminster Superstore", vicinity: "Shudrick Lane, Ilminster", latitude: 50.925638, longitude: -2.909075, storehours: "Mon-Sat: 7:00am - 11:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.tesco.com/store-locator/ilminster/shudrick-ln"),
        Store(name: "Tesco Langport", vicinity: "North Street, Langport", latitude: 51.039884, longitude: -2.827889, storehours: "Mon-Sat: 7:00am - 10:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.tesco.com/store-locator/langport/north-rd"),
        Store(name: "Tesco Rickmansworth", vicinity: "Harefield Road, Rickmansworth", latitude: 51.633744, longitude: -0.470159, storehours: "Mon-Sat: 6:00am - 11:00pm, Sun: 11:00am - 5:00pm", phoneNumber: "+44 345 677 9575", website: "https://www.tesco.com/store-locator/rickmansworth/frogmoor-wharf"),
        Store(name: "Tesco Seaton Superstore", vicinity: "Swan Road, Seaton", latitude: 50.705501, longitude: -3.066841, storehours: "Mon-Sat: 7:00am - Midnight, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.tesco.com/store-locator/seaton/harbour-rd"),
        Store(name: "Tesco Taplow", vicinity: "Maidenhead", latitude: 51.522801, longitude: -0.676114, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.tesco.com/store-locator/taplow/bath-rd"),
        Store(name: "Tesco Taunton", vicinity: "Castle Street, Taunton", latitude: 51.015306, longitude: -3.11157, storehours: "Mon-Sat: 6:00am - Midnight, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.tesco.com/store-locator/taunton/castle-street"),
        Store(name: "Tesco West Drayton", vicinity: "Chantry Close, West Drayton", latitude: 51.515628, longitude: -0.477294, storehours: "Mon-Sat: 7:00am - 11:00pm, Sun: 11:00am - 5:00pm", phoneNumber: "", website: "https://www.tesco.com/store-locator/west-drayton/high-st"),
        Store(name: "Waitrose Bridport", vicinity: "42-44 West Street, Bridport", latitude: 50.733607, longitude: -2.760593, storehours: "Mon-Sat: 8:00am - 8:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.waitrose.com/find-a-store/bridport"),
        Store(name: "Waitrose Chesham", vicinity: "The Backs, Chesham", latitude: 51.70696, longitude: -0.610882, storehours: "Check in-store for current hours", phoneNumber: "+44 1494 791711", website: "https://www.waitrose.com/find-a-store/chesham"),
        Store(name: "Waitrose Crewkerne", vicinity: "South Street, Crewkerne", latitude: 50.883604, longitude: -2.794132, storehours: "Mon-Sat: 8:00am - 8:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.waitrose.com/find-a-store/crewkerne"),
        Store(name: "Waitrose Dorchester", vicinity: "Tudor Arcade, South Street, Dorchester", latitude: 50.714322, longitude: -2.435507, storehours: "Mon-Sat: 8:00am - 8:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "", website: "https://www.waitrose.com/find-a-store/dorchester"),
        Store(name: "Waitrose Ruislip", vicinity: "9 Kingsend, Ruislip", latitude: 51.571324, longitude: -0.423007, storehours: "Mon-Sat: 8:00am - 9:00pm, Sun: 10:00am - 4:00pm", phoneNumber: "+44 1895 631544", website: "https://www.waitrose.com/find-a-store/ruislip"),
        Store(name: "Waitrose Northwood", vicinity: "52 Green Lane, Northwood", latitude: 51.611168, longitude: -0.424317, storehours: "Check in-store for current hours", phoneNumber: "", website: "https://www.waitrose.com/find-a-store/northwood"),
        Store(name: "Waitrose Windsor", vicinity: "37 King Edward Court, Windsor", latitude: 51.482471, longitude: -0.610964, storehours: "Mon-Fri: 8:00am - 9:00pm, Sat: 8:00am - 8:00pm, Sun: 11:00am - 5:00pm", phoneNumber: "+44 1753 860565", website: "https://www.waitrose.com/find-a-store/windsor"),
        // Add more stores here...
    ]

    /// Instance accessor
    var predefinedStores: [Store] { Self.predefinedStores }

    /// Directory stores plus live Apple Maps results near the user. This is what
    /// the map, store list and widget readout should display. Starts from the
    /// cached live results so the list is complete on first render, then
    /// refreshes as the user moves (see `refreshNearbyStores(around:)`).
    @Published private(set) var stores: [Store] = NearbyStoreSearch.merge(
        directory: LocationManager.predefinedStores,
        live: NearbyStoreSearch.cachedStores
    )

    /// In-flight live search, if any. Only one runs at a time.
    private var nearbySearchTask: Task<Void, Never>?

    /// Kicks off a live Apple Maps search around `location` when the cached
    /// results are stale or were fetched somewhere else. Results are merged with
    /// the directory, published on the main thread, cached for offline use and
    /// pushed to the widget's nearest-store readout.
    private func refreshNearbyStores(around location: CLLocation) {
        guard nearbySearchTask == nil else { return }
        guard !NearbyStoreSearch.isCacheFresh(for: location) else { return }
        guard NearbyStoreSearch.canAttempt else { return }

        NearbyStoreSearch.markAttempt()
        // Runs on the main actor so the published properties are mutated there;
        // the MapKit search itself suspends off-main.
        nearbySearchTask = Task { @MainActor [weak self] in
            let live = await NearbyStoreSearch.search(around: location)
            if !live.isEmpty {
                NearbyStoreSearch.saveCache(stores: live, center: location)
            }
            let merged = NearbyStoreSearch.merge(directory: LocationManager.predefinedStores, live: live)

            guard let self else { return }
            self.nearbySearchTask = nil
            // Keep the previous live results if this search came back empty
            // (offline, or MapKit had nothing); the cache still holds them.
            if !live.isEmpty {
                self.stores = merged
                self.publishNearestStoreForWidgets(userLocation: location)
            }
        }
    }
    
    override init() {
        // Initialize region first
        self.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -36.8509, longitude: 174.7633),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
        
        // ✅ CRITICAL: Check if running in extension BEFORE accessing self
        let isExtension = Bundle.main.bundlePath.hasSuffix(".appex")
        
        // Initialize locationManager based on extension check
        if isExtension {
            self.locationManager = nil
        } else {
            self.locationManager = CLLocationManager()
        }
        
        // Now call super.init()
        super.init()
        
        // After super.init(), we can safely access self and configure
        if isExtension {
            print("[LocationManager] Running in extension - location services disabled")
            return
        }
        
        locationManager?.delegate = self
        locationManager?.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager?.distanceFilter = 25
        // Do NOT request authorization in init; let the UI trigger it.
    }

        func startUpdatingLocation() {
            guard let locationManager = locationManager else { return }
            
            // Request permission only when the app actually needs location.
            switch locationManager.authorizationStatus {
            case .notDetermined:
                locationManager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                locationManager.startUpdatingLocation()
            default:
                break
            }
        }

        func stopUpdatingLocation() {
            locationManager?.stopUpdatingLocation()
        }

        func setRegion(to coordinate: CLLocationCoordinate2D) {
            DispatchQueue.main.async {
                self.region = MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
            }
        }

        /// Publishes the nearest store for the home/lock-screen widgets.
        ///
        /// ⚠️ This function used to ALSO register 20 geofences at a 150m radius.
        /// That was a bug: monitored regions are shared across every
        /// CLLocationManager instance in the process, and the app already registers
        /// geofences from `RegionMonitoring` (800m) via the AppDelegate's manager.
        /// Both implementations began by calling `stopMonitoring` on every region,
        /// so each one silently wiped the other's set on every location update.
        ///
        /// Worse, this class implements no `didEnterRegion`, so whenever its
        /// registration won the race, entering a store fired into nothing — no Live
        /// Activity and no notification.
        ///
        /// `RegionMonitoring` is now the single owner of geofences. Do not register
        /// regions here.
        private func publishNearestStoreForWidgets(userLocation: CLLocation) {
            // Snapshot the published list on the caller's (main) thread, then do
            // the distance sort off-main.
            let candidates = stores
            DispatchQueue.global(qos: .utility).async {
                let nearestStore = candidates
                    .map { store -> (store: Store, distance: CLLocationDistance) in
                        let loc = CLLocation(latitude: store.latitude, longitude: store.longitude)
                        return (store, userLocation.distance(from: loc))
                    }
                    .min { $0.distance < $1.distance }

                let nearestStoreName = nearestStore?.store.name
                let nearestStoreDistanceText = nearestStore.map { Self.formatDistance($0.distance) }

                DispatchQueue.main.async {
                    WidgetSnapshot.mutate { snap in
                        snap.nearestStoreName = nearestStoreName
                        snap.nearestStoreDistanceText = nearestStoreDistanceText
                    }
                    if let nearestStoreName { ActivityManager.publishCurrentStore(nearestStoreName) }
                }
            }
        }

        private static func formatDistance(_ distance: CLLocationDistance) -> String {
            if distance < 1000 {
                return "\(Int(distance.rounded())) m"
            }

            let kilometers = distance / 1000
            return String(format: "%.1f km", kilometers)
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let userLocation = locations.last else { return }
            location = userLocation
            setRegion(to: userLocation.coordinate)

            // Refresh the widget's nearest-store readout. Geofencing is owned by
            // RegionMonitoring via the AppDelegate's location manager — not here.
            if !hasConfiguredGeofences {
                hasConfiguredGeofences = true
                publishNearestStoreForWidgets(userLocation: userLocation)
            }

            // Fill in stores the hand-maintained directory doesn't know about.
            // No-op while the cached results are fresh for this area.
            refreshNearbyStores(around: userLocation)
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            authorizationStatus = manager.authorizationStatus

            switch authorizationStatus {
            case .authorizedWhenInUse:
                startUpdatingLocation()

                // Always is only requested once the user has opted into store
                // arrival reminders (Profile). The map itself only needs
                // When-In-Use; the AppDelegate's manager handles the escalation
                // when the opt-in flips, so nothing more to do here.

            case .authorizedAlways:
                startUpdatingLocation()
            case .notDetermined:
                break
            default:
                print("Location permission not granted")
            }
        }
    }
