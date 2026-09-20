import { get, post, requireSession } from "../../utils/api"
import {
  EcardConsumptionItem,
  EcardConsumptionOverviewResponse,
  EcardRoom,
  EcardSummary
} from "../../utils/models"
import {
  parseEcardConsumption,
  parseEcardConsumptionOverview,
  parseEcardRooms,
  parseEcardSummary
} from "../../utils/parsers"

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

    // 历史查询按需加载，避免进入生活缴费页面时额外请求历史接口。
    historyVisible: false,
    historyLoading: false,
    historyError: "",
    historyMonth: currentMonth(),
    historyItems: [] as EcardConsumptionItem[],
    historyOverview: null as EcardConsumptionOverviewResponse | null,

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

  onLoad() {
    if (requireSession()) this.loadSummary()
  },

  async onPullDownRefresh() {
    await this.loadSummary()
    if (this.data.historyVisible && this.data.summary?.status === "ok") {
      await this.loadHistory()
    }
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

  async toggleHistory() {
    if (this.data.historyVisible) {
      this.setData({ historyVisible: false })
      return
    }
    this.setData({ historyVisible: true })
    await this.loadHistory()
  },

  async loadHistory() {
    this.setData({ historyLoading: true, historyError: "" })
    try {
      const [consumption, overview] = await Promise.all([
        get(`/ecard/consumption?month=${this.data.historyMonth}`, parseEcardConsumption),
        get("/ecard/consumption/overview", parseEcardConsumptionOverview)
      ])
      this.setData({ historyItems: consumption.items, historyOverview: overview })
    } catch (error) {
      this.setData({
        historyItems: [],
        historyError: error instanceof Error ? error.message : "水电费历史加载失败"
      })
    } finally {
      this.setData({ historyLoading: false })
    }
  },

  async onHistoryMonthChange(event: WechatMiniprogram.PickerChange) {
    const month = event.detail.value
    if (typeof month !== "string" || !/^\d{4}-\d{2}$/.test(month)) {
      this.setData({ historyError: "查询月份格式无效" })
      return
    }
    this.setData({ historyMonth: month, historyLoading: true, historyError: "" })
    try {
      const consumption = await get(
        `/ecard/consumption?month=${month}`,
        parseEcardConsumption
      )
      this.setData({ historyItems: consumption.items })
    } catch (error) {
      this.setData({
        historyItems: [],
        historyError: error instanceof Error ? error.message : "电费历史加载失败"
      })
    } finally {
      this.setData({ historyLoading: false })
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
        historyItems: [],
        historyOverview: null,
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

function currentMonth(): string {
  const now = new Date()
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`
}
