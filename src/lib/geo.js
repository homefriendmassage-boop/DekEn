// Phone position for "confirm my location" (providers) and "near me" (customers).
// Province level is enough, so a coarse fix is fine and fast. Rejects with 'denied' | 'unavailable' | 'timeout'.
export function getPosition(timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    if (!('geolocation' in navigator)) return reject(new Error('unavailable'))
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ lat: p.coords.latitude, lng: p.coords.longitude }),
      (e) => reject(new Error(e.code === 1 ? 'denied' : e.code === 3 ? 'timeout' : 'unavailable')),
      { enableHighAccuracy: false, timeout: timeoutMs, maximumAge: 60000 },
    )
  })
}
