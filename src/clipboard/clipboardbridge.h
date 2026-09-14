#pragma once

#include "clipboardcodec.h"

#include <QByteArray>
#include <QHash>
#include <QObject>
#include <QStringList>

struct wl_display;
struct wl_registry;
struct wl_seat;
struct ext_data_control_device_v1;
struct ext_data_control_offer_v1;
struct ext_data_control_source_v1;
struct zwlr_data_control_device_v1;
struct zwlr_data_control_offer_v1;
struct zwlr_data_control_source_v1;
class QSocketNotifier;
class QTimer;

namespace FileSail::Clipboard {

class ClipboardBridge final : public QObject {
    Q_OBJECT

public:
    explicit ClipboardBridge(QObject *parent = nullptr);
    ~ClipboardBridge() override;

    void start();
    bool writeFiles(const QStringList &paths, Mode mode, QString *reason);
    bool replaceIfCurrent(const QString &expectedToken, const QStringList &paths,
                          Mode mode, bool clear, QString *reason);
    QJsonObject snapshot() const;
    QJsonObject capabilities() const;

signals:
    void capabilitiesChanged(const QJsonObject &capabilities);
    void snapshotChanged(const QJsonObject &snapshot);
    void protocolError(const QString &reason);

private:
    struct SeatGlobal {
        uint32_t name = 0;
        uint32_t version = 0;
    };
    struct Offer;
    struct Source;
    struct Read;
    struct Send;

    enum class Transport {
        None,
        Ext,
        Wlr,
    };

    void connectWayland();
    void destroyWayland();
    void failWayland(const QString &reason);
    void selectSeatAndTransport();
    void publishSnapshot(const QString &state, const QString &reason = {});
    void handleSelection(void *offerObject);
    void handleOfferMime(void *offerObject, const QString &mime);
    void startRead(void *offerObject, const QString &mime);
    void finishRead(Read *read, bool failed, const QString &reason = {});
    void finishReads();
    void cancelReads();
    void handleSourceCancelled(void *sourceObject);
    void handleSourceSend(void *sourceObject, const QString &mime, int fd);
    void pumpSend(Send *send);
    void flushWayland();

    void *createSource();
    void offerMime(void *source, const char *mime);
    void setSelection(void *source);
    void destroySource(void *source);
    void destroyOffer(void *offer);
    void receiveMime(void *offer, const char *mime, int fd);
    void addDeviceListener();
    void publishOwned(const Payload &payload);

public:
    static void registryGlobal(void *data, wl_registry *registry, uint32_t name,
                               const char *interface, uint32_t version);
    static void registryGlobalRemove(void *data, wl_registry *registry, uint32_t name);
    static void extDataOffer(void *data, struct ext_data_control_device_v1 *device,
                             struct ext_data_control_offer_v1 *offer);
    static void extSelection(void *data, struct ext_data_control_device_v1 *device,
                             struct ext_data_control_offer_v1 *offer);
    static void extFinished(void *data, struct ext_data_control_device_v1 *device);
    static void extPrimarySelection(void *data, struct ext_data_control_device_v1 *device,
                                    struct ext_data_control_offer_v1 *offer);
    static void extSourceSend(void *data, struct ext_data_control_source_v1 *source,
                              const char *mime, int32_t fd);
    static void extSourceCancelled(void *data, struct ext_data_control_source_v1 *source);
    static void extOfferMime(void *data, struct ext_data_control_offer_v1 *offer,
                             const char *mime);
    static void wlrDataOffer(void *data, struct zwlr_data_control_device_v1 *device,
                             struct zwlr_data_control_offer_v1 *offer);
    static void wlrSelection(void *data, struct zwlr_data_control_device_v1 *device,
                             struct zwlr_data_control_offer_v1 *offer);
    static void wlrFinished(void *data, struct zwlr_data_control_device_v1 *device);
    static void wlrPrimarySelection(void *data, struct zwlr_data_control_device_v1 *device,
                                    struct zwlr_data_control_offer_v1 *offer);
    static void wlrSourceSend(void *data, struct zwlr_data_control_source_v1 *source,
                              const char *mime, int32_t fd);
    static void wlrSourceCancelled(void *data, struct zwlr_data_control_source_v1 *source);
    static void wlrOfferMime(void *data, struct zwlr_data_control_offer_v1 *offer,
                             const char *mime);

    void *m_extManager = nullptr;
    void *m_wlrManager = nullptr;
    void *m_device = nullptr;
    wl_display *m_display = nullptr;
    wl_registry *m_registry = nullptr;
    wl_seat *m_seat = nullptr;
    Transport m_transport = Transport::None;
    QList<SeatGlobal> m_seats;
    QString m_seatSetting;
    QString m_capabilityError;
    bool m_available = false;

    Offer *m_currentOffer = nullptr;
    Source *m_currentSource = nullptr;
    QHash<void *, Offer *> m_offers;
    QHash<void *, Source *> m_sources;
    QList<Read *> m_reads;
    QList<Send *> m_sends;
    QHash<QString, QByteArray> m_readResults;
    QString m_helperNonce;
    quint64 m_generation = 0;
    QString m_offerToken;
    Payload m_payload;
    bool m_owned = false;
    QString m_state = QStringLiteral("unavailable");
    QString m_reason;

    ::QSocketNotifier *m_waylandRead = nullptr;
    ::QSocketNotifier *m_waylandWrite = nullptr;
    ::QTimer *m_refreshTimer = nullptr;
};

}
