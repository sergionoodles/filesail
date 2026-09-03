/****************************************************************************
** Meta object code from reading C++ file 'previewservice.h'
**
** Created by: The Qt Meta Object Compiler version 69 (Qt 6.11.2)
**
** WARNING! All changes made in this file will be lost!
*****************************************************************************/

#include "../../../filesail/src/backend/previewservice.h"
#include <QtCore/qmetatype.h>

#include <QtCore/qtmochelpers.h>

#include <memory>


#include <QtCore/qxptype_traits.h>
#if !defined(Q_MOC_OUTPUT_REVISION)
#error "The header file 'previewservice.h' doesn't include <QObject>."
#elif Q_MOC_OUTPUT_REVISION != 69
#error "This file was generated using the moc from 6.11.2. It"
#error "cannot be used with the include files from this version of Qt."
#error "(The moc has changed too much.)"
#endif

#ifndef Q_CONSTINIT
#define Q_CONSTINIT
#endif

QT_WARNING_PUSH
QT_WARNING_DISABLE_DEPRECATED
QT_WARNING_DISABLE_GCC("-Wuseless-cast")
namespace {
struct qt_meta_tag_ZN14PreviewServiceE_t {};
} // unnamed namespace

template <> constexpr inline auto PreviewService::qt_create_metaobjectdata<qt_meta_tag_ZN14PreviewServiceE_t>()
{
    namespace QMC = QtMocConstants;
    QtMocHelpers::StringRefStorage qt_stringData {
        "PreviewService",
        "tumblerReady",
        "",
        "handle",
        "uris",
        "tumblerError",
        "code",
        "message",
        "tumblerFinished"
    };

    QtMocHelpers::UintData qt_methods {
        // Slot 'tumblerReady'
        QtMocHelpers::SlotData<void(uint, const QStringList &)>(1, 2, QMC::AccessPrivate, QMetaType::Void, {{
            { QMetaType::UInt, 3 }, { QMetaType::QStringList, 4 },
        }}),
        // Slot 'tumblerError'
        QtMocHelpers::SlotData<void(uint, const QStringList &, int, const QString &)>(5, 2, QMC::AccessPrivate, QMetaType::Void, {{
            { QMetaType::UInt, 3 }, { QMetaType::QStringList, 4 }, { QMetaType::Int, 6 }, { QMetaType::QString, 7 },
        }}),
        // Slot 'tumblerFinished'
        QtMocHelpers::SlotData<void(uint)>(8, 2, QMC::AccessPrivate, QMetaType::Void, {{
            { QMetaType::UInt, 3 },
        }}),
    };
    QtMocHelpers::UintData qt_properties {
    };
    QtMocHelpers::UintData qt_enums {
    };
    return QtMocHelpers::metaObjectData<PreviewService, qt_meta_tag_ZN14PreviewServiceE_t>(QMC::MetaObjectFlag{}, qt_stringData,
            qt_methods, qt_properties, qt_enums);
}
Q_CONSTINIT const QMetaObject PreviewService::staticMetaObject = { {
    QMetaObject::SuperData::link<QObject::staticMetaObject>(),
    qt_staticMetaObjectStaticContent<qt_meta_tag_ZN14PreviewServiceE_t>.stringdata,
    qt_staticMetaObjectStaticContent<qt_meta_tag_ZN14PreviewServiceE_t>.data,
    qt_static_metacall,
    nullptr,
    qt_staticMetaObjectRelocatingContent<qt_meta_tag_ZN14PreviewServiceE_t>.metaTypes,
    nullptr
} };

void PreviewService::qt_static_metacall(QObject *_o, QMetaObject::Call _c, int _id, void **_a)
{
    auto *_t = static_cast<PreviewService *>(_o);
    if (_c == QMetaObject::InvokeMetaMethod) {
        switch (_id) {
        case 0: _t->tumblerReady((*reinterpret_cast<std::add_pointer_t<uint>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<QStringList>>(_a[2]))); break;
        case 1: _t->tumblerError((*reinterpret_cast<std::add_pointer_t<uint>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<QStringList>>(_a[2])),(*reinterpret_cast<std::add_pointer_t<int>>(_a[3])),(*reinterpret_cast<std::add_pointer_t<QString>>(_a[4]))); break;
        case 2: _t->tumblerFinished((*reinterpret_cast<std::add_pointer_t<uint>>(_a[1]))); break;
        default: ;
        }
    }
}

const QMetaObject *PreviewService::metaObject() const
{
    return QObject::d_ptr->metaObject ? QObject::d_ptr->dynamicMetaObject() : &staticMetaObject;
}

void *PreviewService::qt_metacast(const char *_clname)
{
    if (!_clname) return nullptr;
    if (!strcmp(_clname, qt_staticMetaObjectStaticContent<qt_meta_tag_ZN14PreviewServiceE_t>.strings))
        return static_cast<void*>(this);
    return QObject::qt_metacast(_clname);
}

int PreviewService::qt_metacall(QMetaObject::Call _c, int _id, void **_a)
{
    _id = QObject::qt_metacall(_c, _id, _a);
    if (_id < 0)
        return _id;
    if (_c == QMetaObject::InvokeMetaMethod) {
        if (_id < 3)
            qt_static_metacall(this, _c, _id, _a);
        _id -= 3;
    }
    if (_c == QMetaObject::RegisterMethodArgumentMetaType) {
        if (_id < 3)
            *reinterpret_cast<QMetaType *>(_a[0]) = QMetaType();
        _id -= 3;
    }
    return _id;
}
QT_WARNING_POP
