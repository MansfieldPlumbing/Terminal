using Android.Content;
using Android.Graphics;
using Android.OS;
using Android.Views;
using Android.Webkit;
using Android.Widget;
using System;
using Android.Runtime;

namespace Subsystem;

public class FloatingChatManager
{
    private readonly Context _context;
    private readonly IWindowManager _windowManager;
    private View _floatingView = null!;
    private FrameLayout _container = null!;
    private FrameLayout _dismissContainer = null!;

    public FloatingChatManager(Context context)
    {
        _context = context;
        _windowManager = context.GetSystemService(Context.WindowService)!.JavaCast<IWindowManager>()!;
    }

    public void Show()
    {
        if (_container != null) return;

        _container = new FrameLayout(_context);
        
        _floatingView = new ImageView(_context);
        ((ImageView)_floatingView).SetImageResource(Resource.Mipmap.appicon);
        ((ImageView)_floatingView).SetScaleType(ImageView.ScaleType.CenterCrop);
        _floatingView.OutlineProvider = new ViewOutlineProviderCircular();
        _floatingView.ClipToOutline = true;

        var iconParams = new FrameLayout.LayoutParams(150, 150) {
            Gravity = GravityFlags.Top | GravityFlags.Left
        };
        
        _container.AddView(_floatingView, iconParams);

        var layoutParams = new WindowManagerLayoutParams(
            ViewGroup.LayoutParams.WrapContent,
            ViewGroup.LayoutParams.WrapContent,
            WindowManagerTypes.ApplicationOverlay,
            WindowManagerFlags.NotFocusable,
            Format.Translucent)
        {
            Gravity = GravityFlags.Top | GravityFlags.Left,
            X = 0,
            Y = 200,
            SoftInputMode = SoftInput.AdjustResize
        };

        SetupDismissView();
        AttachTouchListener(layoutParams);

        _windowManager.AddView(_container, layoutParams);
    }

    private void SetupDismissView()
    {
        _dismissContainer = new FrameLayout(_context);
        var dismissButton = new Button(_context) { Text = "✕" };
        dismissButton.SetTextColor(Android.Graphics.Color.White);
        // Dismiss target = error red, the universal "remove" affordance — NOT the old Windows-Phone brand
        // magenta (a drift bug). This is a native overlay outside the WebView, so it can't read var(--error);
        // a neutral error red is the closest theme-honest choice (see risks: seed from Cm --error ideally).
        dismissButton.SetBackgroundColor(Android.Graphics.Color.Rgb(0xC6, 0x28, 0x28));
        dismissButton.SetTextSize(Android.Util.ComplexUnitType.Dip, 24);
        dismissButton.OutlineProvider = new ViewOutlineProviderCircular();
        dismissButton.ClipToOutline = true;

        var lp = new FrameLayout.LayoutParams(180, 180) {
            Gravity = GravityFlags.Center
        };
        _dismissContainer.AddView(dismissButton, lp);
        _dismissContainer.Visibility = ViewStates.Gone;

        var windowParams = new WindowManagerLayoutParams(
            ViewGroup.LayoutParams.MatchParent,
            300,
            WindowManagerTypes.ApplicationOverlay,
            WindowManagerFlags.NotFocusable | WindowManagerFlags.NotTouchable,
            Format.Translucent)
        {
            Gravity = GravityFlags.Bottom | GravityFlags.CenterHorizontal,
            Y = 100 // up from bottom
        };

        _windowManager.AddView(_dismissContainer, windowParams);
    }

    private class ViewOutlineProviderCircular : ViewOutlineProvider
    {
        public override void GetOutline(View view, Outline outline) { outline.SetOval(0, 0, view.Width, view.Height); }
    }

    private Android.Animation.ValueAnimator? _animator;

    private void AttachTouchListener(WindowManagerLayoutParams layoutParams)
    {
        int initialX = 0;
        int initialY = 0;
        float initialTouchX = 0;
        float initialTouchY = 0;
        long touchStartTime = 0;
        bool isDragging = false;
        VelocityTracker? velocityTracker = null;

        var displayMetrics = _context.Resources!.DisplayMetrics!;
        int screenWidth = displayMetrics.WidthPixels;
        int bubbleSize = 150; // As defined in layoutParams

        _floatingView.Touch += (s, e) =>
        {
            switch (e.Event!.ActionMasked)
            {
                case MotionEventActions.Down:
                    _animator?.Cancel();
                    
                    if (velocityTracker == null) velocityTracker = VelocityTracker.Obtain();
                    else velocityTracker.Clear();
                    
                    velocityTracker.AddMovement(e.Event);
                    
                    initialX = layoutParams.X;
                    initialY = layoutParams.Y;
                    initialTouchX = e.Event.RawX;
                    initialTouchY = e.Event.RawY;
                    touchStartTime = Java.Lang.JavaSystem.CurrentTimeMillis();
                    isDragging = false;
                    e.Handled = true;
                    return;

                case MotionEventActions.Move:
                    velocityTracker?.AddMovement(e.Event);
                    
                    float deltaX = e.Event.RawX - initialTouchX;
                    float deltaY = e.Event.RawY - initialTouchY;

                    if (!isDragging && (Math.Abs(deltaX) > 10 || Math.Abs(deltaY) > 10))
                    {
                        isDragging = true;
                        _dismissContainer.Visibility = ViewStates.Visible;
                    }

                    if (isDragging)
                    {
                        layoutParams.X = initialX + (int)deltaX;
                        layoutParams.Y = initialY + (int)deltaY;
                        _windowManager.UpdateViewLayout(_container, layoutParams);
                    }
                    e.Handled = true;
                    return;

                case MotionEventActions.Up:
                case MotionEventActions.Cancel:
                    velocityTracker?.AddMovement(e.Event);
                    velocityTracker?.ComputeCurrentVelocity(1000);
                    float velocityX = velocityTracker?.XVelocity ?? 0;
                    float velocityY = velocityTracker?.YVelocity ?? 0;
                    
                    _dismissContainer.Visibility = ViewStates.Gone;
                    
                    if (isDragging)
                    {
                        int[] dismissLocation = new int[2];
                        _dismissContainer.GetLocationOnScreen(dismissLocation);

                        // Horizontal-throw dismiss: a HARD fling toward either side edge flings the bubble
                        // off-screen and dismisses — you can now "throw it away" sideways, not just drop it
                        // on the bottom target. The threshold (3500 px/s) is well above the snap fling (2000)
                        // so a normal edge-snap fling still just re-docks.
                        const float FlingDismiss = 3500f;
                        bool throwOffRight = velocityX > FlingDismiss;
                        bool throwOffLeft  = velocityX < -FlingDismiss;

                        // Y-only dismiss (drop on the bottom target) — unchanged path.
                        if (e.Event.RawY > dismissLocation[1] - 100)
                        {
                            Hide();
                        }
                        else if (throwOffRight || throwOffLeft)
                        {
                            // Animate the fling all the way off the chosen edge, then drop the overlay.
                            int startX = layoutParams.X;
                            int startY = layoutParams.Y;
                            int targetX = throwOffRight ? screenWidth + bubbleSize : -bubbleSize * 2;
                            int targetY = startY + (int)(velocityY * 0.06f);   // weightier: less Y carry than the old 0.1f

                            _animator = Android.Animation.ValueAnimator.OfFloat(0f, 1f)!;
                            _animator.SetDuration(260);
                            _animator.SetInterpolator(new Android.Views.Animations.AccelerateInterpolator(1.4f)); // accelerate out — it's leaving
                            _animator.Update += (sender, args) =>
                            {
                                float fraction = (float)args.Animation!.AnimatedValue!;
                                layoutParams.X = (int)(startX + (targetX - startX) * fraction);
                                layoutParams.Y = (int)(startY + (targetY - startY) * fraction);
                                if (_container != null) _windowManager.UpdateViewLayout(_container, layoutParams);
                            };
                            _animator.AnimationEnd += (sender, args) => Hide();
                            _animator.Start();
                        }
                        else
                        {
                            // Edge Snapping Physics
                            int currentX = layoutParams.X;
                            int targetX;

                            // If flung (but not hard enough to dismiss), throw it to that side. Otherwise snap to nearest edge.
                            if (velocityX > 2000) targetX = screenWidth - bubbleSize;
                            else if (velocityX < -2000) targetX = 0;
                            else targetX = (currentX + bubbleSize / 2 < screenWidth / 2) ? 0 : screenWidth - bubbleSize;

                            // Carry a little Y momentum when thrown up/down — damped (0.06f) so the head has
                            // WEIGHT and doesn't skate; pairs with the slower, heavier settle below.
                            int currentY = layoutParams.Y;
                            int targetY = currentY + (int)(velocityY * 0.06f);

                            // Keep Y on screen
                            if (targetY < 0) targetY = 0;
                            if (targetY > displayMetrics.HeightPixels - bubbleSize) targetY = displayMetrics.HeightPixels - bubbleSize;

                            _animator = Android.Animation.ValueAnimator.OfFloat(0f, 1f)!;
                            // Heavier spring: longer settle (520ms) + a softer overshoot (0.7) — a weighty
                            // body that eases in and barely bounces, not the old light/snappy 350ms/1.2 flick.
                            _animator.SetDuration(520);
                            _animator.SetInterpolator(new Android.Views.Animations.OvershootInterpolator(0.7f));

                            int startX = currentX;
                            int startY = currentY;

                            _animator.Update += (sender, args) =>
                            {
                                float fraction = (float)args.Animation!.AnimatedValue!;
                                layoutParams.X = (int)(startX + (targetX - startX) * fraction);
                                layoutParams.Y = (int)(startY + (targetY - startY) * fraction);
                                if (_container != null) _windowManager.UpdateViewLayout(_container, layoutParams);
                            };
                            _animator.Start();
                        }
                    }
                    else
                    {
                        long touchDuration = Java.Lang.JavaSystem.CurrentTimeMillis() - touchStartTime;
                        if (touchDuration < 200)
                        {
                            LaunchApp();
                        }
                    }
                    
                    velocityTracker?.Recycle();
                    velocityTracker = null;
                    e.Handled = true;
                    return;
            }
            e.Handled = false;
        };
    }

    private void LaunchApp()
    {
        // The head and the chat panel are ONE object in two states: opening the panel retires the
        // head (Messenger semantics). Route the hide through the service so its overlay state stays true.
        var hide = new Intent(_context, typeof(SubsystemService));
        hide.SetAction(SubsystemService.ActionHideBubble);
        _context.StartService(hide);

        var intent = new Intent(_context, typeof(MainActivity));
        intent.SetAction(Intent.ActionMain);
        intent.AddCategory(Intent.CategoryLauncher);
        intent.PutExtra("open", "agent");   // land ON Broker, not just the shell start screen
        // The head's tap should restore Broker as a FLOATING WINDOW, not relaunch fullscreen. We only
        // carry the intent here; the float campaign consumes openState later (see risks). Minimal seam.
        intent.PutExtra("openState", "window");
        intent.AddFlags(ActivityFlags.NewTask | ActivityFlags.ReorderToFront);
        _context.StartActivity(intent);
    }

    public void Hide()
    {
        if (_container != null)
        {
            _windowManager.RemoveView(_container);
            _container = null!;
        }
        if (_dismissContainer != null)
        {
            _windowManager.RemoveView(_dismissContainer);
            _dismissContainer = null!;
        }
    }
}
