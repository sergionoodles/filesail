#pragma once

#include <QByteArray>
#include <QString>
#include <QStringList>

namespace FileSail::Clipboard {

inline constexpr int MaxFrameBytes = 1024 * 1024;
inline constexpr int MaxMimeBytes = 16 * 1024 * 1024;
inline constexpr int MaxItems = 4096;
inline constexpr int MaxPathBytes = 4096;

enum class Mode {
    Copy,
    Cut,
};

struct Payload {
    Mode mode = Mode::Copy;
    QStringList paths;
};

struct DecodeResult {
    bool ok = false;
    Payload payload;
    QString reason;
};

QString modeName(Mode mode);
bool parseMode(const QString &value, Mode *mode);
QByteArray encodeUriList(const QStringList &paths);
QByteArray encodeGnome(const Payload &payload);
DecodeResult decodeUriList(const QByteArray &bytes);
DecodeResult decodeGnome(const QByteArray &bytes);
DecodeResult decodeOffers(const QByteArray *uriList, const QByteArray *gnome);

}
