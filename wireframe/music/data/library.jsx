// Fictional music library — original artists, albums, tracks.
// All names are invented for this prototype.

const LIBRARY = {
  nowPlaying: {
    trackId: 't1',
    progress: 87, // seconds
    isPlaying: true,
  },
  tracks: [
    { id: 't1', title: 'Chrome Pastoral', artistId: 'a1', albumId: 'al1', duration: 214, plays: '12.4M' },
    { id: 't2', title: 'Velvet Signal',   artistId: 'a1', albumId: 'al1', duration: 198, plays: '8.1M' },
    { id: 't3', title: 'Solar Pager',     artistId: 'a1', albumId: 'al1', duration: 243, plays: '21.9M' },
    { id: 't4', title: 'Aqua 00',         artistId: 'a1', albumId: 'al1', duration: 176, plays: '4.2M' },
    { id: 't5', title: 'Nightbus Halo',   artistId: 'a1', albumId: 'al1', duration: 262, plays: '9.8M' },
    { id: 't6', title: 'Glass Garden',    artistId: 'a1', albumId: 'al1', duration: 189, plays: '3.4M' },
    { id: 't7', title: 'Ceramic Rain',    artistId: 'a2', albumId: 'al2', duration: 221, plays: '15.0M' },
    { id: 't8', title: 'Midori Freeway',  artistId: 'a2', albumId: 'al2', duration: 204, plays: '11.7M' },
    { id: 't9', title: 'Soft Machine',    artistId: 'a3', albumId: 'al3', duration: 256, plays: '6.5M' },
    { id: 't10', title: 'Hologram Youth', artistId: 'a3', albumId: 'al3', duration: 231, plays: '18.2M' },
  ],
  albums: [
    { id: 'al1', title: 'Chrome Pastoral', artistId: 'a1', year: 2024, tracks: 9, color1: '#b8e4ff', color2: '#ffd4f0', color3: '#fff0b8' },
    { id: 'al2', title: 'Ceramic Rain',    artistId: 'a2', year: 2023, tracks: 11, color1: '#d0f0c0', color2: '#a0d8ff', color3: '#ffe8b0' },
    { id: 'al3', title: 'Hologram Youth',  artistId: 'a3', year: 2025, tracks: 8, color1: '#ffb8d4', color2: '#c0c0ff', color3: '#b8fff0' },
    { id: 'al4', title: 'Pearl Interface', artistId: 'a4', year: 2024, tracks: 10, color1: '#fff0e0', color2: '#ffd0d0', color3: '#e0e0ff' },
    { id: 'al5', title: 'Aero',            artistId: 'a5', year: 2022, tracks: 12, color1: '#a0e0ff', color2: '#80b0ff', color3: '#e0f0ff' },
    { id: 'al6', title: 'Soft Protocol',   artistId: 'a6', year: 2025, tracks: 7, color1: '#ffe0a0', color2: '#ffb0a0', color3: '#ffd0e0' },
    { id: 'al7', title: 'Low Tide FM',     artistId: 'a7', year: 2023, tracks: 9, color1: '#c8e8f0', color2: '#a0c8d8', color3: '#f0f8ff' },
    { id: 'al8', title: 'Paperweight',     artistId: 'a8', year: 2024, tracks: 6, color1: '#f0e0d0', color2: '#d0c0b0', color3: '#ffe8d0' },
  ],
  artists: [
    { id: 'a1', name: 'Marisol Kaminari',  tag: 'Ambient Pop',      monthly: '2.4M' },
    { id: 'a2', name: 'Ondine Park',        tag: 'Dream Pop',        monthly: '1.8M' },
    { id: 'a3', name: 'Quiet Rooms',        tag: 'Shoegaze',         monthly: '3.1M' },
    { id: 'a4', name: 'Hiro Nishimura',     tag: 'Electronic',       monthly: '980K' },
    { id: 'a5', name: 'Saffron Mercier',    tag: 'Synthpop',         monthly: '4.2M' },
    { id: 'a6', name: 'Lindell Oates',      tag: 'Indie Folk',       monthly: '620K' },
    { id: 'a7', name: 'The Kelp Orchestra', tag: 'Lo-fi',            monthly: '1.1M' },
    { id: 'a8', name: 'Juneberry',          tag: 'Bedroom Pop',      monthly: '780K' },
  ],
  playlists: [
    { id: 'p1', title: 'Morning Commute',   tracks: 24, desc: 'Low BPM · Cool light' },
    { id: 'p2', title: 'Writing Session',   tracks: 41, desc: 'No vocals · Focus' },
    { id: 'p3', title: 'Saturday Kitchen',  tracks: 32, desc: 'Warm · Upbeat' },
    { id: 'p4', title: 'Rainy Desk',        tracks: 18, desc: 'Ambient · Slow' },
  ],
  genres: [
    { id: 'g1', title: 'Ambient',     color: '#c8e0ff' },
    { id: 'g2', title: 'Electronic',  color: '#ffd4e8' },
    { id: 'g3', title: 'Indie',       color: '#d4f0d0' },
    { id: 'g4', title: 'Jazz',        color: '#ffe8c0' },
    { id: 'g5', title: 'Classical',   color: '#e0d8ff' },
    { id: 'g6', title: 'R&B',         color: '#ffc8c8' },
  ],
};

// helpers
const getArtist = (id) => LIBRARY.artists.find(a => a.id === id);
const getAlbum  = (id) => LIBRARY.albums.find(a => a.id === id);
const getTrack  = (id) => LIBRARY.tracks.find(t => t.id === id);
const tracksForAlbum = (albumId) => LIBRARY.tracks.filter(t => t.albumId === albumId);
const albumsForArtist = (artistId) => LIBRARY.albums.filter(a => a.artistId === artistId);

const fmtTime = (s) => {
  const m = Math.floor(s / 60);
  const ss = Math.floor(s % 60).toString().padStart(2, '0');
  return `${m}:${ss}`;
};

Object.assign(window, {
  LIBRARY, getArtist, getAlbum, getTrack, tracksForAlbum, albumsForArtist, fmtTime,
});
