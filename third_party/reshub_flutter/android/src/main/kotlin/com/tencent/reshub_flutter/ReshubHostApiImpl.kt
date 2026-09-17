package com.tencent.reshub_flutter

import android.app.Application
import android.util.Log
import com.tencent.mmkv.MMKV
import com.tencent.raft.standard.log.IRLog
import com.tencent.rdelivery.dependencyimpl.SystemLog
import com.tencent.rdelivery.reshub.ResConfig
import com.tencent.rdelivery.reshub.api.IRes
import com.tencent.rdelivery.reshub.api.IResCallback
import com.tencent.rdelivery.reshub.api.IResHub
import com.tencent.rdelivery.reshub.api.IResLoadError
import com.tencent.rdelivery.reshub.api.ResHubInstanceExtraParams
import com.tencent.rdelivery.reshub.api.ResHubParams
import com.tencent.rdelivery.reshub.core.OriginDownloadStorageDelegateImpl
import com.tencent.rdelivery.reshub.core.ResHubCenter
import com.tencent.rdelivery.reshub.net.ResHubDefaultDownloadImpl
import com.tencent.rdelivery.reshub.processor.TryPatchProcessor
import com.tencent.rdelivery.reshub.report.ResHubDefaultReportImpl
import com.tencent.rdelivery.reshub.util.RLogImpl

/**
 * Created by raymondhu on 2023/2/14
 */
object ReshubHostApiImpl : MsgProtocolGenerated.ReshubHostAction, MsgProtocolGenerated.ReshubCenterHostAction{

    const val TAG = "ReshubHostApiImpl"

    /**
     * reshub 日志实现代理，可以对接到业务方的日志系统
     */
    private var logDelegate: IRLog? = null
    private var reshub: IResHub? = null
    private var context: Application? = null
    private var hasInitReshubCenter = false
    private var reshubInstanceParams: ResHubParams? = null

    /**
     * 标记已经初始化过ReshubCenter，主要用于java层和flutter层都接入reshub sdk的场景
     * 业务方在java层初始化完ReshubCenter后需要主动调用这个方法，避免flutter层又再次初始化ReshubCenter
     */
    @Synchronized
    fun markHasInitReshubCenter() {
        hasInitReshubCenter = true
    }

    fun setLogDelegate(log: IRLog) {
        logDelegate = log
    }

    @Synchronized
    override fun initReshubCenter(reshubParams: MsgProtocolGenerated.ReshubParams) {
        if (context == null) {
            Log.d(TAG, "initReshubCenter return for null context")
            return
        }
        if (reshubParams == null) {
            Log.d(TAG, "initReshubCenter return for null reshubParams")
            return
        }
        val params = ResHubParams(
            deviceId = reshubParams.deviceId ?: "",
            appVersion = reshubParams.appVersion ?: "",
            isRdmTest = reshubParams.isDebugPackage ?: false,
            variantMap = reshubParams.customParams ?: mapOf(),
            multiProcessMode = true,
            fetchProjectWhenAppOnly = true,
            customServerUrl = reshubParams.customServerUrl
        )
        reshubInstanceParams = params
        if (hasInitReshubCenter) {
            Log.d(TAG, "initReshubCenter return for has initialed")
            return
        }
        MMKV.initialize(context)
        // 必填初始化参数
        ResHubCenter.initWithoutResHubParams(
            context = context!!,
            downloadDelegate = ResHubDefaultDownloadImpl(),
            reportDelegate = ResHubDefaultReportImpl()
        )
        // 开启这个实现，可以让下载的文件保留其原始名称和后缀名
        ResHubCenter.downloadStorageDelegate = OriginDownloadStorageDelegateImpl()
        // 拦截log打印，方便demo查看,如果是debug包并且业务方没有主动注入日志实现，使用SystemLog
        if (reshubParams.isDebugPackage ?: false && logDelegate == null) {
            logDelegate = SystemLog()
        }
        ResHubCenter.logDelegate = logDelegate ?: RLogImpl()
        // 注册这个，可以开启文件差量更新
        ResHubCenter.injectProcessor(listOf(TryPatchProcessor()))
        hasInitReshubCenter = true
    }

    @Synchronized
    override fun initReshub(appId: String, appKey: String, env: String) {
        if (reshub != null) {
            return
        }
        val extraParams = ResHubInstanceExtraParams()
        extraParams.resHubParams = reshubInstanceParams
        reshub = ResHubCenter.getResHub(appId, appKey, env = env,
            extraParams = extraParams)
    }

    fun initApplicationContext(ctx: Application) {
        context = ctx
    }
    override fun get(resId: String): MsgProtocolGenerated.ResModel? {
        Log.d(TAG, "get called $resId")
        val res = reshub?.get(resId)
        return convertToResModel(res)
    }

    override fun getLatest(resId: String): MsgProtocolGenerated.ResModel? {
        Log.d(TAG, "getLatest called $resId")
        val res = reshub?.getLatest(resId)
        return convertToResModel(res)
    }

    override fun getFetchedResConfig(resId: String): MsgProtocolGenerated.ResModel? {
        Log.d(TAG, "getFetchedResConfig called $resId")
        val res = reshub?.getFetchedResConfig(resId)
        return convertToResModel(res)
    }


    override fun load(resId: String, result: MsgProtocolGenerated.Result<MsgProtocolGenerated.LoadResult>?) {
        Log.d(TAG, "load called $resId")
        reshub?.load(resId, object : IResCallback{
            override fun onComplete(isSuccess: Boolean, res: IRes?, error: IResLoadError) {
                val loadResult: MsgProtocolGenerated.LoadResult = convertToLoadResult(isSuccess, res, error)
                result?.success(loadResult)
            }
        })
    }


    override fun loadLatest(resId: String, result: MsgProtocolGenerated.Result<MsgProtocolGenerated.LoadResult>?) {
        Log.d(TAG, "loadLatest called $resId")
        reshub?.loadLatest(resId, object : IResCallback{
            override fun onComplete(isSuccess: Boolean, res: IRes?, error: IResLoadError) {
                val loadResult: MsgProtocolGenerated.LoadResult = convertToLoadResult(isSuccess, res, error)
                result?.success(loadResult)
            }
        })
    }

    override fun loadLatestWithOption(
        resId: String,
        forceRequestRemoteConfig: Boolean,
        result: MsgProtocolGenerated.Result<MsgProtocolGenerated.LoadResult>?
    ) {
        Log.d(TAG, "loadLatestWithOption called $resId, forceRequestRemoteConfig = $forceRequestRemoteConfig")
        reshub?.loadLatest(resId, object : IResCallback{
            override fun onComplete(isSuccess: Boolean, res: IRes?, error: IResLoadError) {
                val loadResult: MsgProtocolGenerated.LoadResult = convertToLoadResult(isSuccess, res, error)
                result?.success(loadResult)
            }
        }, forceRequestRemoteConfig ?: false)
    }

    override fun reportBusinessEvent(
        eventName: String,
        cost: Long,
        errCode: Long,
        extInfo: MutableMap<String, String>,
        reportImmediately: Boolean
    ) {
        reshub?.getRDeliveryInstance()?.reportBusinessEvent(
            eventName ?: "",
            cost ?: 0,
            errCode as? Int ?: 0,
            extInfo ?: emptyMap(),
            reportImmediately ?: false)
    }

    private fun convertToResModel(res: IRes?): MsgProtocolGenerated.ResModel? {
        res ?: return null
        return MsgProtocolGenerated.ResModel().apply {
            resId = res.getResId()
            resVersion = res.getVersion()
            taskId = res.getTaskId()
            resSize = res.getSize()
            resMd5 = res.getMd5()
            localPath = res.getLocalPath()
            val resConfig = res as? ResConfig
            originLocalPath = resConfig?.originLocal
            fileExtra = res.getFileExtra()
        }
    }

    private fun convertToLoadResult(
        success: Boolean,
        result: IRes?,
        err: IResLoadError
    ): MsgProtocolGenerated.LoadResult {
        return MsgProtocolGenerated.LoadResult().apply {
            isSuccess = success
            resModel = convertToResModel(result)
            error = convertToLoadError(err)
        }
    }

    private fun convertToLoadError(err: IResLoadError): MsgProtocolGenerated.LoadError? {
        return MsgProtocolGenerated.LoadError().apply {
            code = err.code().toLong()
            msg = err.message()
        }
    }



}