using Android.App;
using Android.Appwidget;
using Android.Content;
using Android.Widget;

namespace Subsystem.Widgets;

// SubsystemWidgetProvider — the first home-screen widget (LAYER 1: skeleton).
//
// A native RemoteViews card (icon + title + subtitle) whose ONLY job right now is to prove the AppWidget
// plumbing end to end: the [BroadcastReceiver]/[IntentFilter]/[MetaData] attributes generate the manifest
// <receiver> + provider meta-data (the project merges attribute-declared components into AndroidManifest.xml,
// same as the [Service]/[Activity] components), the launcher offers "Subsystem" in its widget picker, the
// card renders on the home screen, and a tap opens the app. There is NO registry data here on purpose —
// that's layer 2. Keeping layer 1 static means a failure is plumbing (receiver/XML/manifest), not Cm init
// from a cold broadcast process.
//
// CANNOT be verified off-device: a widget only proves itself on a real Android home screen. ss-build green
// proves it COMPILES + the resources resolve, nothing more.
[BroadcastReceiver(Label = "Subsystem", Exported = true)]
[IntentFilter(new[] { "android.appwidget.action.APPWIDGET_UPDATE" })]
[MetaData("android.appwidget.provider", Resource = "@xml/subsystem_widget_info")]
public class SubsystemWidgetProvider : AppWidgetProvider
{
    public override void OnUpdate(Context context, AppWidgetManager manager, int[] appWidgetIds)
    {
        foreach (var id in appWidgetIds)
        {
            var views = new RemoteViews(context.PackageName, Resource.Layout.subsystem_widget);

            // Tap anywhere on the card → open the app (its launch activity). Proves the PendingIntent path.
            // Immutable is required on API 31+; UpdateCurrent so re-placement reuses the slot cleanly.
            var launch = context.PackageManager?.GetLaunchIntentForPackage(context.PackageName!);
            if (launch != null)
            {
                var pi = PendingIntent.GetActivity(
                    context, id, launch,
                    PendingIntentFlags.UpdateCurrent | PendingIntentFlags.Immutable);
                views.SetOnClickPendingIntent(Resource.Id.widget_root, pi);
            }

            manager.UpdateAppWidget(id, views);
        }
    }
}
