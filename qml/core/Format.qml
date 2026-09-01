pragma Singleton

import QtQuick

QtObject {
    function size(bytes, isDirectory) {
        if (isDirectory)
            return qsTr("—");
        const units = [qsTr("B"), qsTr("KB"), qsTr("MB"), qsTr("GB"), qsTr("TB")];
        let value = Number(bytes);
        let unit = 0;
        while (value >= 1024 && unit < units.length - 1) {
            value /= 1024;
            unit++;
        }
        return (unit === 0 ? value.toFixed(0) : value.toFixed(value < 10 ? 1 : 0))
            + " " + units[unit];
    }

    function date(isoDate) {
        const value = new Date(isoDate);
        return isNaN(value.getTime()) ? qsTr("—")
            : value.toLocaleString(Qt.locale(), "dd MMM yyyy  HH:mm");
    }
}
