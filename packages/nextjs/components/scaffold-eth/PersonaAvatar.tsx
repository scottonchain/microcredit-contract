"use client";

import { getPersona } from "~~/constants/demoPersonas";

interface PersonaAvatarProps {
  address: string;
  size?: number;
}

/**
 * Renders a colored circle with the persona's initial letter for known demo
 * addresses (Avery / Brighton / Casey).  Falls back to null so the caller
 * can render a BlockieAvatar instead.
 */
export const PersonaAvatar = ({ address, size = 30 }: PersonaAvatarProps) => {
  const persona = getPersona(address);
  if (!persona) return null;

  return (
    <div
      style={{
        width: size,
        height: size,
        borderRadius: "50%",
        backgroundColor: persona.hex,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        flexShrink: 0,
        fontWeight: 700,
        fontSize: Math.round(size * 0.45),
        color: "#fff",
        userSelect: "none",
      }}
      title={`${persona.name} (${persona.role})`}
    >
      {persona.initial}
    </div>
  );
};
