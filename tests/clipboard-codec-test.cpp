#include "clipboardcodec.h"

#include <QCoreApplication>
#include <QDebug>
#include <QUrl>

#include <cstdio>

using namespace FileSail::Clipboard;

namespace {

void check(bool condition, const char *message)
{
    if (!condition) {
        qCritical() << message;
        std::fprintf(stderr, "%s\n", message);
        std::exit(1);
    }
}

}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const QStringList paths{
        QStringLiteral("/tmp/a space/%25/hash#name"),
        QStringLiteral("/tmp/über/cut\nname"),
        QStringLiteral("/tmp/a space/%25/hash#name")};
    const Payload original{Mode::Cut, paths};
    const QByteArray uri = encodeUriList(paths);
    const QByteArray gnome = encodeGnome(original);
    const DecodeResult roundTrip = decodeOffers(&uri, &gnome);
    check(roundTrip.ok, "encoded clipboard did not decode");
    check(roundTrip.payload.mode == Mode::Cut, "GNOME cut metadata was not retained");
    check(roundTrip.payload.paths == QStringList{
        QStringLiteral("/tmp/a space/%25/hash#name"),
        QStringLiteral("/tmp/über/cut\nname")}, "path round trip changed names");

    const QByteArray uriOnly = encodeUriList(QStringList{QStringLiteral("/tmp/copy")});
    const DecodeResult copy = decodeOffers(&uriOnly, nullptr);
    check(copy.ok && copy.payload.mode == Mode::Copy, "URI-only clipboard was not copy");
    check(!decodeUriList("https://example.test/a\n").ok, "remote URI was accepted");
    check(!decodeUriList("file://other-host/a\n").ok, "remote file authority was accepted");
    check(!decodeGnome("move\nfile:///tmp/a\n").ok, "unknown GNOME operation was accepted");
    check(!decodeGnome("cut\nfile:///tmp/a\nfile:///tmp/b\n").ok == false,
          "valid GNOME metadata was rejected");
    const QByteArray conflictingGnome("cut\nfile:///tmp/other\n");
    const DecodeResult conflict = decodeOffers(&uriOnly, &conflictingGnome);
    check(!conflict.ok, "conflicting MIME representations were accepted");
    check(!decodeUriList("file:///tmp/a%ZZ\n").ok, "malformed percent escape was accepted");
    check(!decodeUriList("file:///tmp/a\nhttps://example.test/b\n").ok,
          "mixed local and remote URIs were accepted");
    return 0;
}
