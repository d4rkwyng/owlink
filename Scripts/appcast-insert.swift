// Writes an appcast with one new update <item> added as a direct child of
// its /rss/channel, for Scripts/appcast-item.sh (docs/updates.md). The feed
// is parsed and edited as XML (Foundation's XMLDocument), never as lines.
//
//   swift Scripts/appcast-insert.swift FROM|- OUT VERSION URL LENGTH SIGNATURE PUBDATE
//
// FROM is the feed to add the item to; "-" starts a new feed. The item goes
// before the channel's first item, or at the end of the channel when it has
// none (Sparkle offers the highest version, whatever the order). Sparkle's
// elements use whatever prefix FROM binds to Sparkle's namespace (xmlns:sparkle
// is added to <rss> if none is). An earlier feed signature (the top-level
// "sparkle-signatures:" comment sign_update appends) is dropped: it can't
// match the new content, and the feed is signed again afterwards.
// OUT is written (replaced if there); FROM is only read. External entities
// are never loaded. Exit 1 with a message on any problem.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("appcast-insert.swift: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
guard args.count == 7 else { fail("usage: FROM|- OUT VERSION URL LENGTH SIGNATURE PUBDATE") }
let a = Array(args)
let (from, out, version, url, length, signature, pubDate) = (a[0], a[1], a[2], a[3], a[4], a[5], a[6])

let sparkleNS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
let newFeed = """
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="\(sparkleNS)" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Owlink</title>
    </channel>
</rss>

"""

let readOptions: XMLNode.Options = [.nodePreserveWhitespace, .nodePreserveCDATA, .nodeLoadExternalEntitiesNever]
let doc: XMLDocument
do {
    if from == "-" {
        doc = try XMLDocument(xmlString: newFeed, options: readOptions)
    } else {
        doc = try XMLDocument(data: try Data(contentsOf: URL(fileURLWithPath: from)), options: readOptions)
    }
} catch {
    fail("can't read \(from) as XML: \(error.localizedDescription)")
}

guard let rss = doc.rootElement(), rss.name == "rss", (rss.uri ?? "").isEmpty else {
    fail("\(from): the root element isn't <rss>")
}
let channels = rss.elements(forName: "channel")
guard channels.count == 1, let channel = channels.first else {
    fail("\(from): <rss> has \(channels.count) <channel> elements, not one")
}

// The prefix bound to Sparkle's namespace, else bind "sparkle".
var prefix = rss.resolvePrefix(forNamespaceURI: sparkleNS) ?? ""
if prefix.isEmpty {
    if let taken = rss.namespace(forPrefix: "sparkle"), taken.stringValue != sparkleNS {
        fail("\(from) binds the sparkle: prefix to \(taken.stringValue ?? "?"), not Sparkle's namespace")
    }
    rss.addNamespace(XMLNode.namespace(withName: "sparkle", stringValue: sparkleNS) as! XMLNode)
    prefix = "sparkle"
}

// XMLDocument keeps the source's whitespace but doesn't show it as nodes,
// so the new item is laid out with a fixed indent of its own.
let lead = "\n        "
let inner = lead + "    "
let firstItem = (channel.children ?? []).first { $0.kind == .element && $0.name == "item" && ($0.uri ?? "").isEmpty }

let item = XMLElement(name: "item")
func add(_ child: XMLElement) {
    item.addChild(XMLNode.text(withStringValue: inner) as! XMLNode)
    item.addChild(child)
}
func sparkle(_ name: String, _ value: String) -> XMLElement {
    let element = XMLElement(name: "\(prefix):\(name)", uri: sparkleNS)
    element.stringValue = value
    return element
}
add(XMLElement(name: "title", stringValue: "Version \(version)"))
add(XMLElement(name: "pubDate", stringValue: pubDate))
add(sparkle("version", version))
add(sparkle("shortVersionString", version))
add(sparkle("minimumSystemVersion", "14.0"))
let enclosure = XMLElement(name: "enclosure")
enclosure.addAttribute(XMLNode.attribute(withName: "url", stringValue: url) as! XMLNode)
enclosure.addAttribute(XMLNode.attribute(withName: "length", stringValue: length) as! XMLNode)
enclosure.addAttribute(XMLNode.attribute(withName: "type", stringValue: "application/octet-stream") as! XMLNode)
enclosure.addAttribute(XMLNode.attribute(withName: "\(prefix):edSignature", uri: sparkleNS, stringValue: signature) as! XMLNode)
add(enclosure)
item.addChild(XMLNode.text(withStringValue: lead) as! XMLNode)

if let firstItem {
    // <item new/>[lead]<item first/>
    let at = firstItem.index
    channel.insertChild(item, at: at)
    channel.insertChild(XMLNode.text(withStringValue: lead) as! XMLNode, at: at + 1)
} else {
    channel.addChild(XMLNode.text(withStringValue: lead) as! XMLNode)
    channel.addChild(item)
}

// Drop an earlier feed signature: it covers the old bytes only.
for node in (doc.children ?? []).reversed() where node.kind == .comment {
    if (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sparkle-signatures:") {
        doc.removeChild(at: node.index)
    }
}

doc.isStandalone = false
var data = doc.xmlData(options: [.nodePreserveWhitespace, .nodePreserveCDATA, .nodeCompactEmptyElement])
if data.last != UInt8(ascii: "\n") { data.append(UInt8(ascii: "\n")) }
do {
    try data.write(to: URL(fileURLWithPath: out))
} catch {
    fail("can't write \(out): \(error.localizedDescription)")
}
