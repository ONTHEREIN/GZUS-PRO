import { get, post, requireSession } from "../../utils/api"
import { EcardRoom, EcardSummary } from "../../utils/models"
import { parseEcardRooms, parseEcardSummary } from "../../utils/parsers"

/**
 * 宿舍搜索一次最多返回多少条。
 * 后端全量宿舍约 6700 条（~880KB），所以必须带关键词搜索，不能拉全量。
 */
const ROOM_SEARCH_LIMIT = 50

Page({
  data: {
    loading: true,
    error: "",
    summary: null as EcardSummary | null,

    // 绑定面板
    bindPanelVisible: false,
    keyword: "",
    rooms: [] as EcardRoom[],
    searching: false,
    searchPerformed: false,
    searchError: "",
    bindingRoomId: "",
    bindError: ""
  },

  onShow() {
    if (requireSession()) this.loadSummary()
  },

  async onPullDownRefresh() {
    await this.loadSummary()
    wx.stopPullDownRefresh()
  },

  async loadSummary() {
    this.setData({ loading: true, error: "" })
    try {
      const summary = await get<EcardSummary>("/ecard/summary", parseEcardSummary)
      this.setData({ summary })
    } catch (error) {
      this.setData({ error: error instanceof Error ? error.message : "生活缴费加载失败" })
    } finally {
      this.setData({ loading: false })
    }
  },

  openBindPanel() {
    this.setData({
      bindPanelVisible: true,
      searchError: "",
      bindError: ""
    })
  },

  closeBindPanel() {
    this.setData({
      bindPanelVisible: false,
      keyword: "",
      rooms: [],
      searchPerformed: false,
      searchError: "",
      bindError: ""
    })
  },

  onKeywordInput(event: WechatMiniprogram.Input) {
    this.setData({ keyword: event.detail.value, searchError: "" })
  },

  async searchRooms() {
    const keyword = this.data.keyword.trim()
    if (!keyword) {
      this.setData({ searchError: "请输入楼栋或房间号关键词" })
      return
    }
    this.setData({ searching: true, searchError: "", bindError: "" })
    try {
      const rooms = await get<EcardRoom[]>(
        `/ecard/rooms?q=${encodeURIComponent(keyword)}&limit=${ROOM_SEARCH_LIMIT}`,
        parseEcardRooms
      )
      this.setData({ rooms, searchPerformed: true })
    } catch (error) {
      this.setData({
        rooms: [],
        searchPerformed: true,
        searchError: error instanceof Error ? error.message : "宿舍查询失败"
      })
    } finally {
      this.setData({ searching: false })
    }
  },

  async bindRoom(event: WechatMiniprogram.TouchEvent) {
    if (this.data.bindingRoomId) return
    const index = Number(event.currentTarget.dataset.index)
    const room = this.data.rooms[index]
    if (!room) return

    this.setData({ bindingRoomId: room.id, bindError: "" })
    try {
      // 绑定是本地操作：后端只写自己的绑定记录，随后去读上游余额（较慢，勿加短超时）。
      const summary = await post<EcardSummary>(
        "/ecard/binding",
        { roomId: room.id, roomDisplay: room.displayName },
        parseEcardSummary
      )
      this.setData({
        summary,
        bindPanelVisible: false,
        keyword: "",
        rooms: [],
        searchPerformed: false
      })
      wx.showToast({
        title: `已绑定 ${summary.roomDisplay || room.displayName}`,
        icon: "none"
      })
    } catch (error) {
      this.setData({ bindError: error instanceof Error ? error.message : "宿舍绑定失败" })
    } finally {
      this.setData({ bindingRoomId: "" })
    }
  }
})
