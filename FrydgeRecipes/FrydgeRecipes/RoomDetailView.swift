import SwiftUI

struct RoomDetailView: View {
    @State var room: Room
    @State private var newItemName: String = ""
    @State private var saveStatus: String = "Save"
    @EnvironmentObject var shoppingListManager: ShoppingListManager

    var body: some View {
        VStack {
            List {
                ForEach($room.items) { $item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        Button(action: {
                            item.isChecked.toggle()
                            addToShoppingList(item: item)
                        }) {
                            Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(.blue)
                        }
                    }
                }
            }

            HStack {
                TextField("Add new item", text: $newItemName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button(action: addItem) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.blue)
                }
            }
            .padding()

            Spacer()
        }
        .navigationTitle(room.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saveStatus) { saveRoom() }
                    .foregroundStyle(.blue)
            }
        }
    }

    private func addItem() {
        guard !newItemName.isEmpty else { return }
        room.items.append(RoomItem(name: newItemName))
        newItemName = ""
        saveStatus = "Save"
    }

    private func saveRoom() {
        if saveRoomLocally(room) {
            saveStatus = "Saved"
        } else {
            saveStatus = "Save"
        }
    }

    private func saveRoomLocally(_ room: Room) -> Bool {
        let fileURL = getDocumentsDirectory().appendingPathComponent("roomsData.json")
        var rooms = loadRooms()
        if let index = rooms.firstIndex(where: { $0.id == room.id }) {
            rooms[index] = room
        } else {
            rooms.append(room)
        }

        if let encoded = try? JSONEncoder().encode(rooms) {
            do {
                try encoded.write(to: fileURL)
                print("Room saved successfully.")
                return true
            } catch {
                print("Failed to save room: \(error)")
            }
        }
        return false
    }

    private func loadRooms() -> [Room] {
        let fileURL = getDocumentsDirectory().appendingPathComponent("roomsData.json")
        if let data = try? Data(contentsOf: fileURL),
           let decodedRooms = try? JSONDecoder().decode([Room].self, from: data) {
            return decodedRooms
        }
        return []
    }

    private func addToShoppingList(item: RoomItem) {
            if item.isChecked {
                shoppingListManager.addToShoppingList(item.name) // Pass the name directly as a string
            } else {
                shoppingListManager.removeFromShoppingList(item.name) // Pass the name directly as a string
            }
        }

    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
