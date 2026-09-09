pragma Singleton

import QtQuick

QtObject {
    // Filesystem names are data, not presentation markup. Make invisible and
    // bidirectional controls explicit so extensions and confirmation targets
    // cannot be visually reordered or hidden.
    function safeText(value) {
        return String(value ?? "").replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2060\u2066-\u206f\ufeff]/g,
            character => "⟪U+" + character.charCodeAt(0).toString(16).toUpperCase().padStart(4, "0") + "⟫");
    }

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
