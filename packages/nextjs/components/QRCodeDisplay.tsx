import React from "react";
import { QRCodeSVG } from "qrcode.react";

interface Props {
  value: string;
  size?: number;
}

const QRCodeDisplay: React.FC<Props> = ({ value, size = 128 }) => {
  if (!value) return null;
  return (
    <div className="p-2 bg-white rounded-md border border-gray-300 inline-block">
      <QRCodeSVG value={value} size={size} fgColor="#000000" bgColor="#FFFFFF" />
    </div>
  );
};

export default QRCodeDisplay; 