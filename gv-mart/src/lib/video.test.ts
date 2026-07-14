import { describe, expect, it } from "vitest"
import { getYoutubeThumbnail, getYoutubeVideoId } from "./video"

describe("getYoutubeVideoId", () => {
  it("extracts the id from a watch URL", () => {
    expect(getYoutubeVideoId("https://www.youtube.com/watch?v=dQw4w9WgXcQ")).toBe("dQw4w9WgXcQ")
  })

  it("extracts the id from a watch URL with extra query params", () => {
    expect(getYoutubeVideoId("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")).toBe("dQw4w9WgXcQ")
  })

  it("extracts the id from a youtu.be short link", () => {
    expect(getYoutubeVideoId("https://youtu.be/dQw4w9WgXcQ")).toBe("dQw4w9WgXcQ")
  })

  it("extracts the id from a shorts URL", () => {
    expect(getYoutubeVideoId("https://www.youtube.com/shorts/dQw4w9WgXcQ")).toBe("dQw4w9WgXcQ")
  })

  it("extracts the id from an embed URL", () => {
    expect(getYoutubeVideoId("https://www.youtube.com/embed/dQw4w9WgXcQ")).toBe("dQw4w9WgXcQ")
  })

  it("returns null for a non-YouTube URL", () => {
    expect(getYoutubeVideoId("https://vimeo.com/123456789")).toBeNull()
  })

  it("returns null for an empty string", () => {
    expect(getYoutubeVideoId("")).toBeNull()
  })

  it("returns null for a YouTube URL with no video id (channel link)", () => {
    expect(getYoutubeVideoId("https://www.youtube.com/@gvmart")).toBeNull()
  })
})

describe("getYoutubeThumbnail", () => {
  it("builds a thumbnail URL for a valid YouTube link", () => {
    expect(getYoutubeThumbnail("https://youtu.be/dQw4w9WgXcQ")).toBe("https://img.youtube.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
  })

  it("returns null for a non-YouTube URL", () => {
    expect(getYoutubeThumbnail("https://vimeo.com/123456789")).toBeNull()
  })

  it("returns null for a malformed URL string", () => {
    expect(getYoutubeThumbnail("not a url at all")).toBeNull()
  })
})
