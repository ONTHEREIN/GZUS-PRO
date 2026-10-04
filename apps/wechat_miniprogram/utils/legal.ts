import { legalVersion } from "./generated/legal"

export function hasAcceptedLegal(): boolean {
  return wx.getStorageSync("legal.acceptedVersion") === legalVersion
}

export function acceptLegal(): void {
  wx.setStorageSync("legal.acceptedVersion", legalVersion)
}
