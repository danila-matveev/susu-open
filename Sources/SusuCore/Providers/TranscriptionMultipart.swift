import Foundation

/// multipart/form-data body for `POST /audio/transcriptions`.
struct MultipartForm {
    let boundary: String
    private(set) var body = Data()

    init(boundary: String = "susu-" + UUID().uuidString) { self.boundary = boundary }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    /// Body with the closing boundary.
    func finalized() -> Data {
        var d = body
        d.append(Data("--\(boundary)--\r\n".utf8))
        return d
    }
}
