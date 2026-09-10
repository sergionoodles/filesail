#include "uriresolver.h"

#include <QCoreApplication>
#include <QDebug>

#include <utility>
#include <vector>

int main(int argc, char **argv)
{
    QCoreApplication application(argc, argv);
    const std::vector<std::pair<QString, QString>> cases{
        {"/tmp/example", "/tmp/example"},
        {"/tmp/a/../example", "/tmp/example"},
        {"file:///tmp/a%20b", "/tmp/a b"},
        {"FILE:///tmp/example", "/tmp/example"},
        {"file:///tmp/a%23b", "/tmp/a#b"},
        {"", ""},
        {"relative", ""},
        {"https://example.com/file", ""},
        {"file:relative", ""},
        {"file://remote/tmp/example", ""},
        {"file://user@localhost/tmp/example", ""},
        {"file:///tmp/example?query", ""},
        {"file:///tmp/example#fragment", ""},
        {"file:///tmp/example%00ignored", ""},
        {QStringLiteral("/tmp/example") + QChar::Null + "ignored", ""},
        {"/" + QString(4096, 'a'), ""},
    };
    bool passed = true;
    for (const auto &[input, expected] : cases) {
        const QString actual = FileManager1::localPath(input);
        if (actual != expected) {
            qCritical() << "localPath" << input << "returned" << actual << "expected" << expected;
            passed = false;
        }
    }
    return passed ? 0 : 1;
}
