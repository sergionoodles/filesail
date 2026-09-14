#include "clipboardbridge.h"

#include "ext-data-control-v1-client-protocol.h"
#include "wlr-data-control-unstable-v1-client-protocol.h"

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QSet>
#include <QSocketNotifier>
#include <QTimer>
#include <QUuid>

#include <cerrno>
#include <algorithm>
#include <fcntl.h>
#include <unistd.h>

#include <utility>

#include <wayland-client-core.h>
#include <wayland-client-protocol.h>

namespace FileSail::Clipboard {

struct ClipboardBridge::Offer { ClipboardBridge *bridge; void *object; QStringList mimes; };
struct ClipboardBridge::Source {
    ClipboardBridge *bridge; void *object; Payload payload; QByteArray uri; QByteArray gnome;
};
struct ClipboardBridge::Read {
    ClipboardBridge *bridge; Offer *offer; QString mime; int fd; QByteArray bytes;
    QSocketNotifier *notifier; QTimer *timer;
};
struct ClipboardBridge::Send {
    ClipboardBridge *bridge; Source *source; int fd; QByteArray bytes; qsizetype offset;
    QSocketNotifier *notifier; QTimer *timer;
};

namespace {
constexpr char UriMime[] = "text/uri-list";
constexpr char GnomeMime[] = "x-special/gnome-copied-files";
constexpr int TransferTimeoutMs = 5000;

bool validClipboardPath(const QString &path)
{
    return !path.isEmpty() && !path.contains(QChar::Null) && QDir::isAbsolutePath(path)
        && path.toUtf8().size() <= MaxPathBytes
        && QFile::decodeName(QFile::encodeName(path)) == path;
}

void setNonBlocking(int fd)
{
    const int flags = ::fcntl(fd, F_GETFL, 0);
    if (flags >= 0)
        ::fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}
}

const ext_data_control_device_v1_listener ExtDeviceListener{
    ClipboardBridge::extDataOffer, ClipboardBridge::extSelection, ClipboardBridge::extFinished,
    ClipboardBridge::extPrimarySelection};
const ext_data_control_source_v1_listener ExtSourceListener{
    ClipboardBridge::extSourceSend, ClipboardBridge::extSourceCancelled};
const ext_data_control_offer_v1_listener ExtOfferListener{ClipboardBridge::extOfferMime};
const zwlr_data_control_device_v1_listener WlrDeviceListener{
    ClipboardBridge::wlrDataOffer, ClipboardBridge::wlrSelection,
    ClipboardBridge::wlrFinished, ClipboardBridge::wlrPrimarySelection};
const zwlr_data_control_source_v1_listener WlrSourceListener{
    ClipboardBridge::wlrSourceSend, ClipboardBridge::wlrSourceCancelled};
const zwlr_data_control_offer_v1_listener WlrOfferListener{ClipboardBridge::wlrOfferMime};

ClipboardBridge::ClipboardBridge(QObject *parent)
    : QObject(parent), m_helperNonce(QUuid::createUuid().toString(QUuid::WithoutBraces))
{
}

ClipboardBridge::~ClipboardBridge()
{
    destroyWayland();
}

void ClipboardBridge::start()
{
    publishSnapshot(QStringLiteral("unavailable"), QStringLiteral("clipboard transport is starting"));
    connectWayland();
}

void ClipboardBridge::connectWayland()
{
    m_display = wl_display_connect(nullptr);
    if (!m_display) {
        failWayland(QStringLiteral("could not connect to the Wayland display"));
        return;
    }
    m_registry = wl_display_get_registry(m_display);
    static const wl_registry_listener listener{registryGlobal, registryGlobalRemove};
    if (wl_registry_add_listener(m_registry, &listener, this) < 0) {
        failWayland(QStringLiteral("could not observe the Wayland registry"));
        return;
    }
    if (wl_display_roundtrip(m_display) < 0) {
        failWayland(QStringLiteral("Wayland registry round trip failed"));
        return;
    }
    selectSeatAndTransport();
    if (!m_available)
        return;
    const int fd = wl_display_get_fd(m_display);
    m_waylandRead = new QSocketNotifier(fd, QSocketNotifier::Read, this);
    m_waylandWrite = new QSocketNotifier(fd, QSocketNotifier::Write, this);
    m_waylandWrite->setEnabled(false);
    connect(m_waylandRead, &QSocketNotifier::activated, this, [this] {
        if (!m_display || wl_display_dispatch(m_display) < 0)
            failWayland(QStringLiteral("Wayland display disconnected"));
        else
            flushWayland();
    });
    connect(m_waylandWrite, &QSocketNotifier::activated, this, [this] { flushWayland(); });
    if (wl_display_roundtrip(m_display) < 0) {
        failWayland(QStringLiteral("Wayland data-control setup failed"));
        return;
    }
    flushWayland();
    emit capabilitiesChanged(capabilities());
}

void ClipboardBridge::destroyWayland()
{
    cancelReads();
    for (Send *send : std::as_const(m_sends)) {
        if (send->notifier) send->notifier->deleteLater();
        if (send->timer) send->timer->deleteLater();
        if (send->fd >= 0) ::close(send->fd);
        delete send;
    }
    m_sends.clear();
    if (m_currentOffer) destroyOffer(m_currentOffer->object);
    m_currentOffer = nullptr;
    for (Offer *offer : std::as_const(m_offers)) delete offer;
    m_offers.clear();
    if (m_currentSource) destroySource(m_currentSource->object);
    m_currentSource = nullptr;
    for (Source *source : std::as_const(m_sources)) delete source;
    m_sources.clear();
    if (m_device) {
        if (m_transport == Transport::Ext)
            ext_data_control_device_v1_destroy(static_cast<ext_data_control_device_v1 *>(m_device));
        else if (m_transport == Transport::Wlr)
            zwlr_data_control_device_v1_destroy(static_cast<zwlr_data_control_device_v1 *>(m_device));
    }
    if (m_seat) wl_seat_destroy(m_seat);
    if (m_extManager)
        ext_data_control_manager_v1_destroy(static_cast<ext_data_control_manager_v1 *>(m_extManager));
    if (m_wlrManager)
        zwlr_data_control_manager_v1_destroy(static_cast<zwlr_data_control_manager_v1 *>(m_wlrManager));
    if (m_registry) wl_registry_destroy(m_registry);
    if (m_display) wl_display_disconnect(m_display);
    m_device = nullptr; m_seat = nullptr; m_extManager = nullptr; m_wlrManager = nullptr;
    m_registry = nullptr; m_display = nullptr; m_available = false;
}

void ClipboardBridge::failWayland(const QString &reason)
{
    m_available = false;
    m_capabilityError = reason;
    if (m_waylandRead) m_waylandRead->setEnabled(false);
    if (m_waylandWrite) m_waylandWrite->setEnabled(false);
    publishSnapshot(QStringLiteral("unavailable"), reason);
    emit capabilitiesChanged(capabilities());
}

void ClipboardBridge::selectSeatAndTransport()
{
    m_seatSetting = qEnvironmentVariable("FILESAIL_WAYLAND_SEAT");
    if (!m_extManager && !m_wlrManager) {
        failWayland(QStringLiteral("the compositor exposes neither ext-data-control-v1 nor wlr-data-control"));
        return;
    }
    if (m_seats.isEmpty()) {
        failWayland(QStringLiteral("the compositor exposed no Wayland seat"));
        return;
    }
    SeatGlobal selected;
    bool found = false;
    if (!m_seatSetting.isEmpty()) {
        bool parsed = false;
        const uint32_t requested = m_seatSetting.toUInt(&parsed);
        for (const SeatGlobal &seat : std::as_const(m_seats)) {
            if (parsed && seat.name == requested) { selected = seat; found = true; break; }
        }
        if (!found) {
            failWayland(QStringLiteral("FILESAIL_WAYLAND_SEAT does not identify a known seat"));
            return;
        }
    } else if (m_seats.size() == 1) {
        selected = m_seats.constFirst(); found = true;
    } else {
        failWayland(QStringLiteral("multiple Wayland seats are present; set FILESAIL_WAYLAND_SEAT to a global name"));
        return;
    }
    if (!found) return;
    m_seat = static_cast<wl_seat *>(wl_registry_bind(m_registry, selected.name, &wl_seat_interface,
                                                     qMin(selected.version, 4u)));
    if (!m_seat) { failWayland(QStringLiteral("could not bind the selected Wayland seat")); return; }
    if (m_extManager) {
        m_transport = Transport::Ext;
        m_device = ext_data_control_manager_v1_get_data_device(
            static_cast<ext_data_control_manager_v1 *>(m_extManager), m_seat);
    } else {
        m_transport = Transport::Wlr;
        m_device = zwlr_data_control_manager_v1_get_data_device(
            static_cast<zwlr_data_control_manager_v1 *>(m_wlrManager), m_seat);
    }
    if (!m_device) { failWayland(QStringLiteral("could not create a Wayland data-control device")); return; }
    addDeviceListener();
    m_available = true;
    m_capabilityError.clear();
    m_seatSetting = QString::number(selected.name);
}

QJsonObject ClipboardBridge::capabilities() const
{
    return {{"available", m_available},
            {"transport", m_transport == Transport::Ext ? "ext-data-control-v1"
                           : m_transport == Transport::Wlr ? "wlr-data-control-unstable-v1" : "none"},
            {"seat", m_seatSetting}, {"maxFrameBytes", MaxFrameBytes},
            {"maxMimeBytes", MaxMimeBytes}, {"maxItems", MaxItems},
            {"maxPathBytes", MaxPathBytes}, {"reason", m_capabilityError}};
}

QJsonObject ClipboardBridge::snapshot() const
{
    QJsonArray paths;
    for (const QString &path : m_payload.paths) paths.append(path);
    return {{"available", m_available}, {"transport", m_transport == Transport::Ext ? "ext-data-control-v1"
                           : m_transport == Transport::Wlr ? "wlr-data-control-unstable-v1" : "none"},
            {"ready", m_state == "ready"}, {"owned", m_owned}, {"state", m_state}, {"offerToken", m_offerToken},
            {"generation", static_cast<qint64>(m_generation)}, {"mode", modeName(m_payload.mode)},
            {"paths", paths}, {"supported", m_state == "ready" || m_state == "empty"},
            {"reason", m_reason}};
}

void ClipboardBridge::publishSnapshot(const QString &state, const QString &reason)
{
    m_state = state; m_reason = reason; emit snapshotChanged(snapshot());
}

void ClipboardBridge::publishOwned(const Payload &payload)
{
    m_payload = payload; m_owned = true; ++m_generation;
    m_offerToken = m_helperNonce + QLatin1Char(':') + QString::number(m_generation);
    publishSnapshot(QStringLiteral("ready"));
}

bool ClipboardBridge::writeFiles(const QStringList &paths, Mode mode, QString *reason)
{
    if (!m_available) { if (reason) *reason = m_capabilityError; return false; }
    if (paths.isEmpty() || paths.size() > MaxItems) {
        if (reason)
            *reason = QStringLiteral("clipboard path count is outside the supported limit");
        return false;
    }
    QStringList unique;
    QSet<QString> seen;
    for (const QString &path : paths) {
        if (!validClipboardPath(path)) {
            if (reason)
                *reason = QStringLiteral("clipboard paths must be absolute local paths");
            return false;
        }
        if (!seen.contains(path)) { seen.insert(path); unique.append(path); }
    }
    Source *source = new Source{this, createSource(), {mode, unique}, {}, {}};
    if (!source->object) {
        delete source; if (reason) *reason = QStringLiteral("could not create a Wayland clipboard source"); return false;
    }
    source->uri = encodeUriList(unique); source->gnome = encodeGnome(source->payload);
    if (source->uri.size() > MaxMimeBytes || source->gnome.size() > MaxMimeBytes) {
        destroySource(source->object); delete source;
        if (reason)
            *reason = QStringLiteral("clipboard MIME data is too large");
        return false;
    }
    m_sources.insert(source->object, source);
    wl_proxy_set_user_data(static_cast<wl_proxy *>(source->object), source);
    if (m_transport == Transport::Ext)
        ext_data_control_source_v1_add_listener(static_cast<ext_data_control_source_v1 *>(source->object), &ExtSourceListener, this);
    else
        zwlr_data_control_source_v1_add_listener(static_cast<zwlr_data_control_source_v1 *>(source->object), &WlrSourceListener, this);
    offerMime(source->object, UriMime); offerMime(source->object, GnomeMime);
    setSelection(source->object); m_currentSource = source; publishOwned(source->payload); flushWayland();
    return true;
}

bool ClipboardBridge::replaceIfCurrent(const QString &expectedToken, const QStringList &paths,
                                       Mode mode, bool clear, QString *reason)
{
    if (m_display) wl_display_dispatch_pending(m_display);
    if (!m_available || !m_owned || expectedToken.isEmpty() || expectedToken != m_offerToken) {
        if (reason)
            *reason = QStringLiteral("clipboard offer is no longer owned by this helper");
        return false;
    }
    if (clear || paths.isEmpty()) {
        setSelection(nullptr); m_owned = false; m_payload = {}; ++m_generation;
        m_offerToken = m_helperNonce + QLatin1Char(':') + QString::number(m_generation);
        publishSnapshot(QStringLiteral("empty")); flushWayland(); return true;
    }
    return writeFiles(paths, mode, reason);
}

void ClipboardBridge::handleSelection(void *offerObject)
{
    Offer *offer = offerObject ? m_offers.value(offerObject, nullptr) : nullptr;
    if (m_currentOffer && m_currentOffer != offer) {
        cancelReads(); destroyOffer(m_currentOffer->object); m_offers.remove(m_currentOffer->object);
        delete m_currentOffer;
    }
    m_currentOffer = offer;
    if (m_owned) { publishSnapshot(QStringLiteral("ready")); return; }
    ++m_generation; m_offerToken = m_helperNonce + QLatin1Char(':') + QString::number(m_generation);
    m_payload = {}; m_readResults.clear();
    if (!offer) { publishSnapshot(QStringLiteral("empty")); return; }
    const bool hasUri = offer->mimes.contains(QString::fromLatin1(UriMime));
    const bool hasGnome = offer->mimes.contains(QString::fromLatin1(GnomeMime));
    if (!hasUri && !hasGnome) {
        publishSnapshot(QStringLiteral("unsupported"), QStringLiteral("clipboard has no supported file MIME type")); return;
    }
    publishSnapshot(QStringLiteral("reading"));
    if (hasUri) startRead(offer->object, QString::fromLatin1(UriMime));
    if (hasGnome) startRead(offer->object, QString::fromLatin1(GnomeMime));
}

void ClipboardBridge::handleOfferMime(void *offerObject, const QString &mime)
{
    Offer *offer = m_offers.value(offerObject, nullptr);
    if (offer && !offer->mimes.contains(mime)) offer->mimes.append(mime);
}

void ClipboardBridge::startRead(void *offerObject, const QString &mime)
{
    int fds[2] = {-1, -1};
    if (::pipe2(fds, O_CLOEXEC) != 0) {
        publishSnapshot(QStringLiteral("unsupported"), QStringLiteral("could not create clipboard receive pipe")); return;
    }
    Read *read = new Read{this, m_offers.value(offerObject, nullptr), mime, fds[0], {}, nullptr, nullptr};
    if (!read->offer) { ::close(fds[0]); ::close(fds[1]); delete read; return; }
    receiveMime(offerObject, mime.toUtf8().constData(), fds[1]);
    ::close(fds[1]);
    setNonBlocking(read->fd);
    flushWayland();
    read->notifier = new QSocketNotifier(read->fd, QSocketNotifier::Read, this);
    read->timer = new QTimer(this); read->timer->setSingleShot(true); read->timer->setInterval(TransferTimeoutMs);
    connect(read->notifier, &QSocketNotifier::activated, this, [this, read] {
        char buffer[8192];
        while (true) {
            const ssize_t count = ::read(read->fd, buffer, sizeof(buffer));
            if (count > 0) {
                read->bytes.append(buffer, static_cast<qsizetype>(count));
                if (read->bytes.size() > MaxMimeBytes) { finishRead(read, true, QStringLiteral("clipboard MIME data is too large")); return; }
                continue;
            }
            if (count == 0) { finishRead(read, false); return; }
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            finishRead(read, true, QStringLiteral("clipboard MIME read failed")); return;
        }
    });
    connect(read->timer, &QTimer::timeout, this, [this, read] {
        finishRead(read, true, QStringLiteral("clipboard MIME read timed out"));
    });
    m_reads.append(read); read->timer->start();
}

void ClipboardBridge::finishRead(Read *read, bool failed, const QString &reason)
{
    if (!m_reads.contains(read)) return;
    if (read->notifier) read->notifier->setEnabled(false);
    if (read->timer) read->timer->stop();
    if (!failed && read->offer == m_currentOffer) m_readResults.insert(read->mime, read->bytes);
    m_reads.removeOne(read);
    if (read->notifier)
        read->notifier->deleteLater();
    if (read->timer)
        read->timer->deleteLater();
    ::close(read->fd); delete read;
    if (failed) { cancelReads(); publishSnapshot(QStringLiteral("unsupported"), reason); return; }
    if (m_reads.isEmpty()) finishReads();
}

void ClipboardBridge::finishReads()
{
    if (!m_currentOffer) return;
    const QByteArray *uri = m_readResults.contains(QString::fromLatin1(UriMime))
        ? &m_readResults[QString::fromLatin1(UriMime)] : nullptr;
    const QByteArray *gnome = m_readResults.contains(QString::fromLatin1(GnomeMime))
        ? &m_readResults[QString::fromLatin1(GnomeMime)] : nullptr;
    const DecodeResult result = decodeOffers(uri, gnome);
    if (!result.ok) { publishSnapshot(QStringLiteral("unsupported"), result.reason); return; }
    m_payload = result.payload; publishSnapshot(QStringLiteral("ready"));
}

void ClipboardBridge::cancelReads()
{
    for (Read *read : std::as_const(m_reads)) {
        if (read->notifier)
            read->notifier->setEnabled(false);
        if (read->timer)
            read->timer->stop();
        if (read->notifier)
            read->notifier->deleteLater();
        if (read->timer)
            read->timer->deleteLater();
        if (read->fd >= 0)
            ::close(read->fd);
        delete read;
    }
    m_reads.clear(); m_readResults.clear();
}

void ClipboardBridge::handleSourceCancelled(void *sourceObject)
{
    Source *source = m_sources.value(sourceObject, nullptr); if (!source) return;
    if (source == m_currentSource) {
        m_currentSource = nullptr; m_owned = false;
        if (m_currentOffer) handleSelection(m_currentOffer->object); else publishSnapshot(QStringLiteral("empty"));
    }
    m_sources.remove(sourceObject); destroySource(sourceObject); delete source;
}

void ClipboardBridge::handleSourceSend(void *sourceObject, const QString &mime, int fd)
{
    Source *source = m_sources.value(sourceObject, nullptr);
    if (!source || (mime != QString::fromLatin1(UriMime) && mime != QString::fromLatin1(GnomeMime))) { ::close(fd); return; }
    setNonBlocking(fd);
    Send *send = new Send{this, source, fd,
        mime == QString::fromLatin1(UriMime) ? source->uri : source->gnome, 0, nullptr, nullptr};
    send->notifier = new QSocketNotifier(fd, QSocketNotifier::Write, this);
    send->timer = new QTimer(this); send->timer->setSingleShot(true); send->timer->setInterval(TransferTimeoutMs);
    connect(send->notifier, &QSocketNotifier::activated, this, [this, send] { pumpSend(send); });
    connect(send->timer, &QTimer::timeout, this, [this, send] {
        const int index = m_sends.indexOf(send); if (index < 0) return; m_sends.removeAt(index);
        ::close(send->fd); send->notifier->deleteLater(); send->timer->deleteLater(); delete send;
    });
    m_sends.append(send); send->timer->start(); pumpSend(send);
}

void ClipboardBridge::pumpSend(Send *send)
{
    if (!m_sends.contains(send)) return;
    while (send->offset < send->bytes.size()) {
        const ssize_t count = ::write(send->fd, send->bytes.constData() + send->offset,
                                      static_cast<size_t>(send->bytes.size() - send->offset));
        if (count > 0) { send->offset += static_cast<qsizetype>(count); continue; }
        if (errno == EAGAIN || errno == EWOULDBLOCK) return;
        break;
    }
    const int index = m_sends.indexOf(send); if (index < 0) return; m_sends.removeAt(index);
    if (send->notifier)
        send->notifier->setEnabled(false);
    if (send->timer)
        send->timer->stop();
    ::close(send->fd); send->notifier->deleteLater(); send->timer->deleteLater(); delete send;
}

void ClipboardBridge::flushWayland()
{
    if (!m_display) return;
    const int result = wl_display_flush(m_display);
    if (result < 0 && errno != EAGAIN) { failWayland(QStringLiteral("Wayland display flush failed")); return; }
    if (m_waylandWrite) m_waylandWrite->setEnabled(result < 0 && errno == EAGAIN);
}

void *ClipboardBridge::createSource()
{
    return m_transport == Transport::Ext
        ? ext_data_control_manager_v1_create_data_source(static_cast<ext_data_control_manager_v1 *>(m_extManager))
        : static_cast<void *>(zwlr_data_control_manager_v1_create_data_source(static_cast<zwlr_data_control_manager_v1 *>(m_wlrManager)));
}
void ClipboardBridge::offerMime(void *source, const char *mime)
{
    if (m_transport == Transport::Ext) ext_data_control_source_v1_offer(static_cast<ext_data_control_source_v1 *>(source), mime);
    else zwlr_data_control_source_v1_offer(static_cast<zwlr_data_control_source_v1 *>(source), mime);
}
void ClipboardBridge::setSelection(void *source)
{
    if (m_transport == Transport::Ext) ext_data_control_device_v1_set_selection(static_cast<ext_data_control_device_v1 *>(m_device), static_cast<ext_data_control_source_v1 *>(source));
    else zwlr_data_control_device_v1_set_selection(static_cast<zwlr_data_control_device_v1 *>(m_device), static_cast<zwlr_data_control_source_v1 *>(source));
}
void ClipboardBridge::destroySource(void *source)
{
    if (!source) return;
    if (m_transport == Transport::Ext) ext_data_control_source_v1_destroy(static_cast<ext_data_control_source_v1 *>(source));
    else zwlr_data_control_source_v1_destroy(static_cast<zwlr_data_control_source_v1 *>(source));
}
void ClipboardBridge::destroyOffer(void *offer)
{
    if (!offer) return;
    if (m_transport == Transport::Ext) ext_data_control_offer_v1_destroy(static_cast<ext_data_control_offer_v1 *>(offer));
    else zwlr_data_control_offer_v1_destroy(static_cast<zwlr_data_control_offer_v1 *>(offer));
}
void ClipboardBridge::receiveMime(void *offer, const char *mime, int fd)
{
    if (m_transport == Transport::Ext) ext_data_control_offer_v1_receive(static_cast<ext_data_control_offer_v1 *>(offer), mime, fd);
    else zwlr_data_control_offer_v1_receive(static_cast<zwlr_data_control_offer_v1 *>(offer), mime, fd);
}
void ClipboardBridge::addDeviceListener()
{
    if (m_transport == Transport::Ext) ext_data_control_device_v1_add_listener(static_cast<ext_data_control_device_v1 *>(m_device), &ExtDeviceListener, this);
    else zwlr_data_control_device_v1_add_listener(static_cast<zwlr_data_control_device_v1 *>(m_device), &WlrDeviceListener, this);
}

void ClipboardBridge::registryGlobal(void *data, wl_registry *registry, uint32_t name,
                                     const char *interface, uint32_t version)
{
    auto *bridge = static_cast<ClipboardBridge *>(data);
    if (qstrcmp(interface, "ext_data_control_manager_v1") == 0 && !bridge->m_extManager)
        bridge->m_extManager = wl_registry_bind(registry, name, &ext_data_control_manager_v1_interface, qMin(version, 1u));
    else if (qstrcmp(interface, "zwlr_data_control_manager_v1") == 0 && !bridge->m_wlrManager)
        bridge->m_wlrManager = wl_registry_bind(registry, name, &zwlr_data_control_manager_v1_interface, qMin(version, 2u));
    else if (qstrcmp(interface, "wl_seat") == 0)
        bridge->m_seats.append({name, qMin(version, 4u)});
}
void ClipboardBridge::registryGlobalRemove(void *data, wl_registry *, uint32_t name)
{
    auto *bridge = static_cast<ClipboardBridge *>(data);
    bridge->m_seats.erase(std::remove_if(bridge->m_seats.begin(), bridge->m_seats.end(),
                                         [name](const SeatGlobal &seat) { return seat.name == name; }), bridge->m_seats.end());
}

void ClipboardBridge::extDataOffer(void *data, ext_data_control_device_v1 *, ext_data_control_offer_v1 *offer)
{
    auto *bridge = static_cast<ClipboardBridge *>(data); auto *context = new Offer{bridge, offer, {}};
    bridge->m_offers.insert(offer, context); wl_proxy_set_user_data(reinterpret_cast<wl_proxy *>(offer), context);
    ext_data_control_offer_v1_add_listener(offer, &ExtOfferListener, bridge);
}
void ClipboardBridge::extSelection(void *data, ext_data_control_device_v1 *, ext_data_control_offer_v1 *offer)
{ static_cast<ClipboardBridge *>(data)->handleSelection(offer); }
void ClipboardBridge::extFinished(void *data, ext_data_control_device_v1 *)
{ static_cast<ClipboardBridge *>(data)->failWayland(QStringLiteral("Wayland data-control device finished")); }
void ClipboardBridge::extPrimarySelection(void *data, ext_data_control_device_v1 *, ext_data_control_offer_v1 *offer)
{
    if (!offer)
        return;
    auto *bridge = static_cast<ClipboardBridge *>(data);
    bridge->destroyOffer(offer);
    delete bridge->m_offers.take(offer);
}
void ClipboardBridge::extSourceSend(void *data, ext_data_control_source_v1 *source, const char *mime, int32_t fd)
{ static_cast<ClipboardBridge *>(data)->handleSourceSend(source, QString::fromUtf8(mime), fd); }
void ClipboardBridge::extSourceCancelled(void *data, ext_data_control_source_v1 *source)
{ static_cast<ClipboardBridge *>(data)->handleSourceCancelled(source); }
void ClipboardBridge::extOfferMime(void *data, ext_data_control_offer_v1 *offer, const char *mime)
{ static_cast<ClipboardBridge *>(data)->handleOfferMime(offer, QString::fromUtf8(mime)); }

void ClipboardBridge::wlrDataOffer(void *data, zwlr_data_control_device_v1 *, zwlr_data_control_offer_v1 *offer)
{
    auto *bridge = static_cast<ClipboardBridge *>(data); auto *context = new Offer{bridge, offer, {}};
    bridge->m_offers.insert(offer, context); wl_proxy_set_user_data(reinterpret_cast<wl_proxy *>(offer), context);
    zwlr_data_control_offer_v1_add_listener(offer, &WlrOfferListener, bridge);
}
void ClipboardBridge::wlrSelection(void *data, zwlr_data_control_device_v1 *, zwlr_data_control_offer_v1 *offer)
{ static_cast<ClipboardBridge *>(data)->handleSelection(offer); }
void ClipboardBridge::wlrFinished(void *data, zwlr_data_control_device_v1 *)
{ static_cast<ClipboardBridge *>(data)->failWayland(QStringLiteral("Wayland data-control device finished")); }
void ClipboardBridge::wlrPrimarySelection(void *data, zwlr_data_control_device_v1 *, zwlr_data_control_offer_v1 *offer)
{
    if (!offer)
        return;
    auto *bridge = static_cast<ClipboardBridge *>(data);
    bridge->destroyOffer(offer);
    delete bridge->m_offers.take(offer);
}
void ClipboardBridge::wlrSourceSend(void *data, zwlr_data_control_source_v1 *source, const char *mime, int32_t fd)
{ static_cast<ClipboardBridge *>(data)->handleSourceSend(source, QString::fromUtf8(mime), fd); }
void ClipboardBridge::wlrSourceCancelled(void *data, zwlr_data_control_source_v1 *source)
{ static_cast<ClipboardBridge *>(data)->handleSourceCancelled(source); }
void ClipboardBridge::wlrOfferMime(void *data, zwlr_data_control_offer_v1 *offer, const char *mime)
{ static_cast<ClipboardBridge *>(data)->handleOfferMime(offer, QString::fromUtf8(mime)); }

}
