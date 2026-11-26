package dev.orbitarrow.orbit_arrow_overdrive

import android.content.Context
import android.util.Log
import com.google.android.gms.games.PlayGames
import com.google.android.gms.games.PlayGamesSdk
import com.google.android.gms.games.SnapshotsClient
import com.google.android.gms.games.snapshot.Snapshot
import com.google.android.gms.games.snapshot.SnapshotMetadataChange
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

internal class CampaignCloudSave(
    private val activity: MainActivity,
    messenger: BinaryMessenger,
) {
    private val enabled = activity.getString(R.string.game_services_project_id).isNotBlank()
    private val channel = MethodChannel(messenger, "orbit_arrow/cloud_save")
    private val preferences = activity.getSharedPreferences("orbit_cloud_save", Context.MODE_PRIVATE)

    init {
        if (enabled) PlayGamesSdk.initialize(activity.applicationContext)
        channel.setMethodCallHandler { call, result ->
            val campaign = call.arguments as? String
            when {
                call.method != "sync" && call.method != "signInAndSync" -> result.notImplemented()
                !enabled -> result.success(null)
                campaign == null -> result.error("cloud_save", "Missing campaign progress", null)
                else -> sync(campaign, call.method == "signInAndSync").addOnCompleteListener { task ->
                    if (task.isSuccessful) {
                        if (task.result != null) Log.i("OrbitArrow", "Play Games campaign sync complete")
                        result.success(task.result)
                    } else {
                        Log.w("OrbitArrow", "Play Games campaign sync failed", task.exception)
                        result.error("cloud_save", task.exception?.message, null)
                    }
                }
            }
        }
    }

    fun close() = channel.setMethodCallHandler(null)

    private fun sync(campaign: String, signIn: Boolean): Task<String?> {
        val signInClient = PlayGames.getGamesSignInClient(activity)
        val authenticationTask = signInClient.isAuthenticated.continueWithTask { authentication ->
            val status = authentication.result
            if (signIn && !status.isAuthenticated) signInClient.signIn() else Tasks.forResult(status)
        }
        return authenticationTask.continueWithTask { authentication ->
            if (!authentication.result.isAuthenticated) {
                return@continueWithTask Tasks.forResult(null)
            }
            PlayGames.getPlayersClient(activity).currentPlayer.continueWithTask playerTask@{ player ->
                val account = player.result.playerId
                val previous = preferences.getString("player_id", null)
                if (previous != null && previous != account) {
                    return@playerTask Tasks.forResult(null)
                }
                // Bind the device's existing campaign before sending it to Play Games.
                preferences.edit().putString("player_id", account).apply()
                val client = PlayGames.getSnapshotsClient(activity)
                val wallet = JSONObject(campaign).optJSONObject("wallet")?.toString().orEmpty()
                val campaignTask = syncSnapshot(client, "orbit-campaign-v1", campaign, ::mergeCampaign)
                // Older builds can keep updating campaign progress without dropping the wallet.
                val walletTask = syncSnapshot(client, "orbit-wallet-v1", wallet, ::mergeWallet)
                Tasks.whenAll(campaignTask, walletTask).continueWith<String?> {
                    val progress = campaignTask.result
                    val balance = walletTask.result
                    if (balance.isEmpty()) progress
                    else JSONObject(progress).put("wallet", JSONObject(balance)).toString()
                }
            }
        }
    }

    private fun syncSnapshot(
        client: SnapshotsClient,
        name: String,
        local: String,
        merge: (Array<out String>) -> String,
    ): Task<String> =
        client.open(name, true, SnapshotsClient.RESOLUTION_POLICY_MANUAL)
            .continueWithTask { opened -> mergeSnapshot(client, opened.result, local, merge) }

    private fun mergeSnapshot(
        client: SnapshotsClient,
        opened: SnapshotsClient.DataOrConflict<Snapshot>,
        local: String,
        merge: (Array<out String>) -> String,
        conflictsRemaining: Int = 3,
    ): Task<String> {
        if (opened.isConflict) {
            val conflict = checkNotNull(opened.conflict)
            check(conflictsRemaining > 0) { "Campaign changed on another device" }
            val merged = merge(arrayOf(local, contents(conflict.snapshot), contents(conflict.conflictingSnapshot)))
            val resolution = conflict.resolutionSnapshotContents
            check(resolution.writeBytes(merged.toByteArray(Charsets.UTF_8)))
            return client.resolveConflict(
                conflict.conflictId,
                conflict.snapshot.metadata.snapshotId,
                SnapshotMetadataChange.EMPTY_CHANGE,
                resolution,
            ).continueWithTask { resolved ->
                mergeSnapshot(client, resolved.result, merged, merge, conflictsRemaining - 1)
            }
        }

        val snapshot = checkNotNull(opened.data)
        val cloud = contents(snapshot)
        val merged = merge(arrayOf(local, cloud))
        if (cloud == merged) {
            client.discardAndClose(snapshot)
            return Tasks.forResult(merged)
        }
        check(snapshot.snapshotContents.writeBytes(merged.toByteArray(Charsets.UTF_8)))
        return client.commitAndClose(snapshot, SnapshotMetadataChange.EMPTY_CHANGE)
            .continueWith { committed ->
                committed.result
                merged
            }
    }

    private fun contents(snapshot: Snapshot): String =
        snapshot.snapshotContents.readFully().toString(Charsets.UTF_8)

    private fun mergeWallet(snapshots: Array<out String>): String {
        var updatedAt = 0L
        var gems = 0
        for (snapshot in snapshots.filter(String::isNotBlank)) {
            val wallet = JSONObject(snapshot)
            val version = wallet.getLong("updatedAt")
            val balance = wallet.getInt("gems")
            require(version in 1L..9007199254740991L && balance in 0..1000000000)
            if (version > updatedAt || (version == updatedAt && balance < gems)) {
                updatedAt = version
                gems = balance
            }
        }
        if (updatedAt == 0L) return ""
        return JSONObject().put("updatedAt", updatedAt).put("gems", gems).toString()
    }

    private fun mergeCampaign(snapshots: Array<out String>): String {
        var unlocked = 1
        var enteredThrough = 1
        val stars = IntArray(251)
        for (snapshot in snapshots.filter(String::isNotBlank)) {
            val data = JSONObject(snapshot)
            require(data.getString("format") == "orbit.campaign.v1")
            val frontier = data.getInt("unlocked")
            val paid = data.getInt("enteredThrough")
            require(frontier in 1..250 && paid in 1..frontier)
            unlocked = maxOf(unlocked, frontier)
            enteredThrough = maxOf(enteredThrough, paid)
            val ratings = data.getJSONObject("stars")
            for (key in ratings.keys()) {
                val stage = key.toInt()
                val rating = ratings.getInt(key)
                require(stage in 1..250 && rating in 0..3)
                stars[stage] = maxOf(stars[stage], rating)
            }
        }
        val ratings = JSONObject()
        for (stage in 1..250) {
            if (stars[stage] > 0) ratings.put(stage.toString(), stars[stage])
        }
        return JSONObject()
            .put("format", "orbit.campaign.v1")
            .put("unlocked", unlocked)
            .put("enteredThrough", enteredThrough)
            .put("stars", ratings)
            .toString()
    }
}
