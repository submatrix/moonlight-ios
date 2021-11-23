//
//  ControllerSupport.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "ControllerSupport.h"
#import "Controller.h"

#import "OnScreenControls.h"

#import "DataManager.h"
#include "Limelight.h"

@import GameController;
@import AudioToolbox;

static const double MOUSE_SPEED_DIVISOR = 2.5;

@implementation ControllerSupport {
    id _controllerConnectObserver;
    id _controllerDisconnectObserver;
    id _mouseConnectObserver;
    id _mouseDisconnectObserver;
    id _keyboardConnectObserver;
    id _keyboardDisconnectObserver;
    
    NSLock *_controllerStreamLock;
    NSMutableDictionary *_controllers;
    id<InputPresenceDelegate> _presenceDelegate;
    
    float accumulatedDeltaX;
    float accumulatedDeltaY;
    float accumulatedScrollY;
    
    OnScreenControls *_osc;
    
    // This controller object is shared between on-screen controls
    // and player 0
    Controller *_player0osc;
    
#define EMULATING_SELECT     0x1
#define EMULATING_SPECIAL    0x2
    
    bool _oscEnabled;
    char _controllerNumbers;
    bool _multiController;
}

// UPDATE_BUTTON_FLAG(controller, flag, pressed)
#define UPDATE_BUTTON_FLAG(controller, x, y) \
((y) ? [self setButtonFlag:controller flags:x] : [self clearButtonFlag:controller flags:x])

-(void) rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor
{
    Controller* controller = [_controllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
    if (controller == nil && controllerNumber == 0 && _oscEnabled) {
        // No physical controller, but we have on-screen controls
        controller = _player0osc;
    }
    if (controller == nil) {
        // No connected controller for this player
        return;
    }
    
    [controller.lowFreqMotor setMotorAmplitude:lowFreqMotor];
    [controller.highFreqMotor setMotorAmplitude:highFreqMotor];
}

-(void) updateLeftStick:(Controller*)controller x:(short)x y:(short)y
{
    @synchronized(controller) {
        controller.lastLeftStickX = x;
        controller.lastLeftStickY = y;
    }
}

-(void) updateRightStick:(Controller*)controller x:(short)x y:(short)y
{
    @synchronized(controller) {
        controller.lastRightStickX = x;
        controller.lastRightStickY = y;
    }
}

-(void) updateLeftTrigger:(Controller*)controller left:(unsigned char)left
{
    @synchronized(controller) {
        controller.lastLeftTrigger = left;
    }
}

-(void) updateRightTrigger:(Controller*)controller right:(unsigned char)right
{
    @synchronized(controller) {
        controller.lastRightTrigger = right;
    }
}

-(void) updateTriggers:(Controller*) controller left:(unsigned char)left right:(unsigned char)right
{
    @synchronized(controller) {
        controller.lastLeftTrigger = left;
        controller.lastRightTrigger = right;
    }
}

-(void) handleSpecialCombosReleased:(Controller*)controller releasedButtons:(int)releasedButtons
{
    if ((controller.emulatingButtonFlags & EMULATING_SELECT) && (releasedButtons & (LB_FLAG | PLAY_FLAG))) {
        controller.lastButtonFlags &= ~BACK_FLAG;
        controller.emulatingButtonFlags &= ~EMULATING_SELECT;
    }
    
    if (controller.emulatingButtonFlags & EMULATING_SPECIAL) {
        // If Select is emulated, we use RB+Start to emulate special, otherwise we use Start+Select
        if (controller.supportedEmulationFlags & EMULATING_SELECT) {
            if (releasedButtons & (RB_FLAG | PLAY_FLAG)) {
                controller.lastButtonFlags &= ~SPECIAL_FLAG;
                controller.emulatingButtonFlags &= ~EMULATING_SPECIAL;
            }
        }
        else {
            if (releasedButtons & (BACK_FLAG | PLAY_FLAG)) {
                controller.lastButtonFlags &= ~SPECIAL_FLAG;
                controller.emulatingButtonFlags &= ~EMULATING_SPECIAL;
            }
        }
    }
}

-(void) handleSpecialCombosPressed:(Controller*)controller pressedButtons:(int)pressedButtons
{
    // Special button combos for select and special
    if (controller.lastButtonFlags & PLAY_FLAG) {
        // If LB and start are down, trigger select
        if (controller.lastButtonFlags & LB_FLAG) {
            if (controller.supportedEmulationFlags & EMULATING_SELECT) {
                controller.lastButtonFlags |= BACK_FLAG;
                controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | LB_FLAG));
                controller.emulatingButtonFlags |= EMULATING_SELECT;
            }
        }
        else if (controller.supportedEmulationFlags & EMULATING_SPECIAL) {
            // If Select is emulated too, use RB+Start to emulate special
            if (controller.supportedEmulationFlags & EMULATING_SELECT) {
                if (controller.lastButtonFlags & RB_FLAG) {
                    controller.lastButtonFlags |= SPECIAL_FLAG;
                    controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | RB_FLAG));
                    controller.emulatingButtonFlags |= EMULATING_SPECIAL;
                }
            }
            else {
                // If Select is physical, use Start+Select to emulate special
                if (controller.lastButtonFlags & BACK_FLAG) {
                    controller.lastButtonFlags |= SPECIAL_FLAG;
                    controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | BACK_FLAG));
                    controller.emulatingButtonFlags |= EMULATING_SPECIAL;
                }
            }
        }
    }
}

-(void) updateButtonFlags:(Controller*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags = flags;
        
        // This must be called before handleSpecialCombosPressed
        // because we clear the original button flags there
        int releasedButtons = (controller.lastButtonFlags ^ flags) & ~flags;
        int pressedButtons = (controller.lastButtonFlags ^ flags) & flags;
        
        [self handleSpecialCombosReleased:controller releasedButtons:releasedButtons];
        
        [self handleSpecialCombosPressed:controller pressedButtons:pressedButtons];
    }
}

-(void) setButtonFlag:(Controller*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags |= flags;
        [self handleSpecialCombosPressed:controller pressedButtons:flags];
    }
}

-(void) clearButtonFlag:(Controller*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags &= ~flags;
        [self handleSpecialCombosReleased:controller releasedButtons:flags];
    }
}

-(void) updateFinished:(Controller*)controller
{
    [_controllerStreamLock lock];
    @synchronized(controller) {
        // Player 1 is always present for OSC
        LiSendMultiControllerEvent(_multiController ? controller.playerIndex : 0,
                                   (_multiController ? _controllerNumbers : 1) | (_oscEnabled ? 1 : 0), controller.lastButtonFlags, controller.lastLeftTrigger, controller.lastRightTrigger, controller.lastLeftStickX, controller.lastLeftStickY, controller.lastRightStickX, controller.lastRightStickY);
    }
    [_controllerStreamLock unlock];
}

+(BOOL) hasKeyboardOrMouse {
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        return GCMouse.mice.count > 0 || GCKeyboard.coalescedKeyboard != nil;
    }
    else {
        return NO;
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

-(void) unregisterControllerCallbacks:(GCController*) controller
{
    if (controller != NULL) {
        controller.controllerPausedHandler = NULL;
        
        if (controller.extendedGamepad != NULL) {
            // Re-enable system gestures on the gamepad buttons now
            if (@available(iOS 14.0, tvOS 14.0, *)) {
                for (GCControllerElement* element in controller.extendedGamepad.allElements) {
                    element.preferredSystemGestureState = GCSystemGestureStateEnabled;
                }
            }
            
            controller.extendedGamepad.valueChangedHandler = NULL;
        }
        else if (controller.gamepad != NULL) {
            controller.gamepad.valueChangedHandler = NULL;
        }
    }
}

-(void) initializeControllerHaptics:(Controller*) controller
{
    controller.lowFreqMotor = [HapticContext createContextForLowFreqMotor:controller.gamepad];
    controller.highFreqMotor = [HapticContext createContextForHighFreqMotor:controller.gamepad];
}

-(void) cleanupControllerHaptics:(Controller*) controller
{
    [controller.lowFreqMotor cleanup];
    [controller.highFreqMotor cleanup];
}

-(void) registerControllerCallbacks:(GCController*) controller
{
    if (controller != NULL) {
        // iOS 13 allows the Start button to behave like a normal button, however
        // older MFi controllers can send an instant down+up event for the start button
        // which means the button will not be down long enough to register on the PC.
        // To work around this issue, use the old controllerPausedHandler if the controller
        // doesn't have a Select button (which indicates it probably doesn't have a proper
        // Start button either).
        BOOL useLegacyPausedHandler = YES;
        if (@available(iOS 13.0, tvOS 13.0, *)) {
            if (controller.extendedGamepad != nil &&
                controller.extendedGamepad.buttonOptions != nil) {
                useLegacyPausedHandler = NO;
            }
        }
        
        if (useLegacyPausedHandler) {
            controller.controllerPausedHandler = ^(GCController *controller) {
                Controller* limeController = [self->_controllers objectForKey:[NSNumber numberWithInteger:controller.playerIndex]];
                
                // Get off the main thread
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                    [self setButtonFlag:limeController flags:PLAY_FLAG];
                    [self updateFinished:limeController];
                    
                    // Pause for 100 ms
                    usleep(100 * 1000);
                    
                    [self clearButtonFlag:limeController flags:PLAY_FLAG];
                    [self updateFinished:limeController];
                });
            };
        }
        
        if (controller.extendedGamepad != NULL) {
            // Disable system gestures on the gamepad to avoid interfering
            // with in-game controller actions
            if (@available(iOS 14.0, tvOS 14.0, *)) {
                for (GCControllerElement* element in controller.extendedGamepad.allElements) {
                    element.preferredSystemGestureState = GCSystemGestureStateDisabled;
                }
            }
            
            controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
                Controller* limeController = [self->_controllers objectForKey:[NSNumber numberWithInteger:gamepad.controller.playerIndex]];
                short leftStickX, leftStickY;
                short rightStickX, rightStickY;
                unsigned char leftTrigger, rightTrigger;
                
                UPDATE_BUTTON_FLAG(limeController, A_FLAG, gamepad.buttonA.pressed);
                UPDATE_BUTTON_FLAG(limeController, B_FLAG, gamepad.buttonB.pressed);
                UPDATE_BUTTON_FLAG(limeController, X_FLAG, gamepad.buttonX.pressed);
                UPDATE_BUTTON_FLAG(limeController, Y_FLAG, gamepad.buttonY.pressed);
                
                UPDATE_BUTTON_FLAG(limeController, UP_FLAG, gamepad.dpad.up.pressed);
                UPDATE_BUTTON_FLAG(limeController, DOWN_FLAG, gamepad.dpad.down.pressed);
                UPDATE_BUTTON_FLAG(limeController, LEFT_FLAG, gamepad.dpad.left.pressed);
                UPDATE_BUTTON_FLAG(limeController, RIGHT_FLAG, gamepad.dpad.right.pressed);
                
                UPDATE_BUTTON_FLAG(limeController, LB_FLAG, gamepad.leftShoulder.pressed);
                UPDATE_BUTTON_FLAG(limeController, RB_FLAG, gamepad.rightShoulder.pressed);
                
                // Yay, iOS 12.1 now supports analog stick buttons
                if (@available(iOS 12.1, tvOS 12.1, *)) {
                    if (gamepad.leftThumbstickButton != nil) {
                        UPDATE_BUTTON_FLAG(limeController, LS_CLK_FLAG, gamepad.leftThumbstickButton.pressed);
                    }
                    if (gamepad.rightThumbstickButton != nil) {
                        UPDATE_BUTTON_FLAG(limeController, RS_CLK_FLAG, gamepad.rightThumbstickButton.pressed);
                    }
                }
                
                if (@available(iOS 13.0, tvOS 13.0, *)) {
                    // Options button is optional (only present on Xbox One S and PS4 gamepads)
                    if (gamepad.buttonOptions != nil) {
                        UPDATE_BUTTON_FLAG(limeController, BACK_FLAG, gamepad.buttonOptions.pressed);

                        // For older MFi gamepads, the menu button will already be handled by
                        // the controllerPausedHandler.
                        UPDATE_BUTTON_FLAG(limeController, PLAY_FLAG, gamepad.buttonMenu.pressed);
                    }
                }
                
                if (@available(iOS 14.0, tvOS 14.0, *)) {
                    // Home/Guide button is optional (only present on Xbox One S and PS4 gamepads)
                    if (gamepad.buttonHome != nil) {
                        UPDATE_BUTTON_FLAG(limeController, SPECIAL_FLAG, gamepad.buttonHome.pressed);
                    }
                }
                
                leftStickX = gamepad.leftThumbstick.xAxis.value * 0x7FFE;
                leftStickY = gamepad.leftThumbstick.yAxis.value * 0x7FFE;
                
                rightStickX = gamepad.rightThumbstick.xAxis.value * 0x7FFE;
                rightStickY = gamepad.rightThumbstick.yAxis.value * 0x7FFE;
                
                leftTrigger = gamepad.leftTrigger.value * 0xFF;
                rightTrigger = gamepad.rightTrigger.value * 0xFF;
                
                [self updateLeftStick:limeController x:leftStickX y:leftStickY];
                [self updateRightStick:limeController x:rightStickX y:rightStickY];
                [self updateTriggers:limeController left:leftTrigger right:rightTrigger];
                [self updateFinished:limeController];
            };
        }
        else if (controller.gamepad != NULL) {
            controller.gamepad.valueChangedHandler = ^(GCGamepad *gamepad, GCControllerElement *element) {
                Controller* limeController = [self->_controllers objectForKey:[NSNumber numberWithInteger:gamepad.controller.playerIndex]];
                UPDATE_BUTTON_FLAG(limeController, A_FLAG, gamepad.buttonA.pressed);
                UPDATE_BUTTON_FLAG(limeController, B_FLAG, gamepad.buttonB.pressed);
                UPDATE_BUTTON_FLAG(limeController, X_FLAG, gamepad.buttonX.pressed);
                UPDATE_BUTTON_FLAG(limeController, Y_FLAG, gamepad.buttonY.pressed);
                
                UPDATE_BUTTON_FLAG(limeController, UP_FLAG, gamepad.dpad.up.pressed);
                UPDATE_BUTTON_FLAG(limeController, DOWN_FLAG, gamepad.dpad.down.pressed);
                UPDATE_BUTTON_FLAG(limeController, LEFT_FLAG, gamepad.dpad.left.pressed);
                UPDATE_BUTTON_FLAG(limeController, RIGHT_FLAG, gamepad.dpad.right.pressed);
                
                UPDATE_BUTTON_FLAG(limeController, LB_FLAG, gamepad.leftShoulder.pressed);
                UPDATE_BUTTON_FLAG(limeController, RB_FLAG, gamepad.rightShoulder.pressed);
                
                [self updateFinished:limeController];
            };
        }
    } else {
        Log(LOG_W, @"Tried to register controller callbacks on NULL controller");
    }
}

-(void) unregisterMouseCallbacks:(GCMouse*)mouse API_AVAILABLE(ios(14.0)) {
    mouse.mouseInput.mouseMovedHandler = nil;
    
    mouse.mouseInput.leftButton.pressedChangedHandler = nil;
    mouse.mouseInput.middleButton.pressedChangedHandler = nil;
    mouse.mouseInput.rightButton.pressedChangedHandler = nil;
    
    for (GCControllerButtonInput* auxButton in mouse.mouseInput.auxiliaryButtons) {
        auxButton.pressedChangedHandler = nil;
    }
}

-(void) registerMouseCallbacks:(GCMouse*) mouse API_AVAILABLE(ios(14.0)) {
    mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
        self->accumulatedDeltaX += deltaX / MOUSE_SPEED_DIVISOR;
        self->accumulatedDeltaY += -deltaY / MOUSE_SPEED_DIVISOR;
        
        short truncatedDeltaX = (short)self->accumulatedDeltaX;
        short truncatedDeltaY = (short)self->accumulatedDeltaY;
        
        if (truncatedDeltaX != 0 || truncatedDeltaY != 0) {
            LiSendMouseMoveEvent(truncatedDeltaX, truncatedDeltaY);
            
            self->accumulatedDeltaX -= truncatedDeltaX;
            self->accumulatedDeltaY -= truncatedDeltaY;
        }
    };
    
    mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    };
    mouse.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_MIDDLE);
    };
    mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
    };
    
    if (mouse.mouseInput.auxiliaryButtons != nil) {
        if (mouse.mouseInput.auxiliaryButtons.count >= 1) {
            mouse.mouseInput.auxiliaryButtons[0].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X1);
            };
        }
        if (mouse.mouseInput.auxiliaryButtons.count >= 2) {
            mouse.mouseInput.auxiliaryButtons[1].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X2);
            };
        }
    }
    
    // We use UIPanGestureRecognizer on iPadOS because it allows us to distinguish
    // between discrete and continuous scroll events and also works around a bug
    // in iPadOS 15 where discrete scroll events are dropped. tvOS only supports
    // GCMouse for mice, so we will have to just use it and hope for the best.
#if TARGET_OS_TV
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        self->accumulatedScrollY += -value;
        
        short truncatedScrollY = (short)self->accumulatedScrollY;
        
        if (truncatedScrollY != 0) {
            LiSendHighResScrollEvent(truncatedScrollY);
            
            self->accumulatedScrollY -= truncatedScrollY;
        }
    };
#endif
}

-(void) updateAutoOnScreenControlMode
{
    // Auto on-screen control support may not be enabled
    if (_osc == NULL) {
        return;
    }
    
    OnScreenControlsLevel level = OnScreenControlsLevelFull;
    
    // We currently stop after the first controller we find.
    // Maybe we'll want to change that logic later.
    for (int i = 0; i < [[GCController controllers] count]; i++) {
        GCController *controller = [GCController controllers][i];
        
        if (controller != NULL) {
            if (controller.extendedGamepad != NULL) {
                level = OnScreenControlsLevelAutoGCExtendedGamepad;
                if (@available(iOS 12.1, tvOS 12.1, *)) {
                    if (controller.extendedGamepad.leftThumbstickButton != nil &&
                        controller.extendedGamepad.rightThumbstickButton != nil) {
                        level = OnScreenControlsLevelAutoGCExtendedGamepadWithStickButtons;
                        if (@available(iOS 13.0, tvOS 13.0, *)) {
                            if (controller.extendedGamepad.buttonOptions != nil) {
                                // Has L3/R3 and Select, so we can show nothing :)
                                level = OnScreenControlsLevelOff;
                            }
                        }
                    }
                }
                break;
            }
            else if (controller.gamepad != NULL) {
                level = OnScreenControlsLevelAutoGCGamepad;
                break;
            }
        }
    }
    
    // If we didn't find a gamepad present and we have a keyboard or mouse, turn
    // the on-screen controls off to get the overlays out of the way.
    if (level == OnScreenControlsLevelFull && [ControllerSupport hasKeyboardOrMouse]) {
        level = OnScreenControlsLevelOff;
        
        // Ensure the virtual gamepad disappears to avoid confusing some games.
        // If the mouse and keyboard disconnect later, it will reappear when the
        // first OSC input is received.
        LiSendMultiControllerEvent(0, 0, 0, 0, 0, 0, 0, 0, 0);
    }
    
    [_osc setLevel:level];
}

-(void) initAutoOnScreenControlMode:(OnScreenControls*)osc
{
    _osc = osc;
    
    [self updateAutoOnScreenControlMode];
}

-(void) assignController:(GCController*)controller {
    for (int i = 0; i < 4; i++) {
        if (!(_controllerNumbers & (1 << i))) {
            _controllerNumbers |= (1 << i);
            controller.playerIndex = i;
            
            Controller* limeController;

            if (i == 0) {
                // Player 0 shares a controller object with the on-screen controls
                limeController = _player0osc;
            } else {
                limeController = [[Controller alloc] init];
                limeController.playerIndex = i;
            }
            
            limeController.supportedEmulationFlags = EMULATING_SPECIAL | EMULATING_SELECT;
            limeController.gamepad = controller;
            
            if (@available(iOS 13.0, tvOS 13.0, *)) {
                if (controller.extendedGamepad != nil &&
                    controller.extendedGamepad.buttonOptions != nil) {
                    // Disable select button emulation since we have a physical select button
                    limeController.supportedEmulationFlags &= ~EMULATING_SELECT;
                }
            }
            
            if (@available(iOS 14.0, tvOS 14.0, *)) {
                if (controller.extendedGamepad != nil &&
                    controller.extendedGamepad.buttonHome != nil) {
                    // Disable special button emulation since we have a physical special button
                    limeController.supportedEmulationFlags &= ~EMULATING_SPECIAL;
                }
            }
            
            // Prepare controller haptics for use
            [self initializeControllerHaptics:limeController];

            [_controllers setObject:limeController forKey:[NSNumber numberWithInteger:controller.playerIndex]];
            
            Log(LOG_I, @"Assigning controller index: %d", i);
            break;
        }
    }
}

-(Controller*) getOscController {
    return _player0osc;
}

+(bool) isSupportedGamepad:(GCController*) controller {
    return controller.extendedGamepad != nil || controller.gamepad != nil;
}

#pragma clang diagnostic pop

+(int) getGamepadCount {
    int count = 0;
    
    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            count++;
        }
    }
    
    return count;
}

+(int) getConnectedGamepadMask:(StreamConfiguration*)streamConfig {
    int mask = 0;
    
    if (streamConfig.multiController) {
        int i = 0;
        for (GCController* controller in [GCController controllers]) {
            if ([ControllerSupport isSupportedGamepad:controller]) {
                mask |= 1 << i++;
            }
        }
    }
    else {
        // Some games don't deal with having controller reconnected
        // properly so always report controller 1 if not in MC mode
        mask = 0x1;
    }
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* settings = [dataMan getSettings];
    OnScreenControlsLevel level = (OnScreenControlsLevel)[settings.onscreenControls integerValue];
    
    // Even if no gamepads are present, we will always count one if OSC is enabled,
    // or it's set to auto and no keyboard or mouse is present. Absolute touch mode
    // disables the OSC.
    if (level != OnScreenControlsLevelOff && (![ControllerSupport hasKeyboardOrMouse] || level != OnScreenControlsLevelAuto) && !settings.absoluteTouchMode) {
        mask |= 0x1;
    }
    
    return mask;
}

-(NSUInteger) getConnectedGamepadCount
{
    return _controllers.count;
}

-(id) initWithConfig:(StreamConfiguration*)streamConfig presenceDelegate:(id<InputPresenceDelegate>)delegate
{
    self = [super init];
    
    _controllerStreamLock = [[NSLock alloc] init];
    _controllers = [[NSMutableDictionary alloc] init];
    _controllerNumbers = 0;
    _multiController = streamConfig.multiController;
    _presenceDelegate = delegate;

    _player0osc = [[Controller alloc] init];
    _player0osc.playerIndex = 0;

    DataManager* dataMan = [[DataManager alloc] init];
    _oscEnabled = (OnScreenControlsLevel)[[dataMan getSettings].onscreenControls integerValue] != OnScreenControlsLevelOff;
    
    Log(LOG_I, @"Number of supported controllers connected: %d", [ControllerSupport getGamepadCount]);
    Log(LOG_I, @"Multi-controller: %d", _multiController);
    
    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            [self assignController:controller];
            [self registerControllerCallbacks:controller];
        }
    }
    
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        for (GCMouse* mouse in [GCMouse mice]) {
            [self registerMouseCallbacks:mouse];
        }
    }
    
    _controllerConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        Log(LOG_I, @"Controller connected!");
        
        GCController* controller = note.object;
        
        if (![ControllerSupport isSupportedGamepad:controller]) {
            // Ignore micro gamepads and motion controllers
            return;
        }
        
        [self assignController:controller];
        
        // Register callbacks on the new controller
        [self registerControllerCallbacks:controller];
        
        // Re-evaluate the on-screen control mode
        [self updateAutoOnScreenControlMode];
        
        // Notify the delegate
        [self->_presenceDelegate gamepadPresenceChanged];
    }];
    _controllerDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        Log(LOG_I, @"Controller disconnected!");
        
        GCController* controller = note.object;
        
        if (![ControllerSupport isSupportedGamepad:controller]) {
            // Ignore micro gamepads and motion controllers
            return;
        }
        
        [self unregisterControllerCallbacks:controller];
        self->_controllerNumbers &= ~(1 << controller.playerIndex);
        Log(LOG_I, @"Unassigning controller index: %ld", (long)controller.playerIndex);
        
        // Unset the GCController on this object (in case it is the OSC, which will persist)
        Controller* limeController = [self->_controllers objectForKey:[NSNumber numberWithInteger:controller.playerIndex]];
        
        // Stop haptics on this controller
        [self cleanupControllerHaptics:limeController];
        
        limeController.gamepad = nil;
        
        // Inform the server of the updated active gamepads before removing this controller
        [self updateFinished:limeController];
        [self->_controllers removeObjectForKey:[NSNumber numberWithInteger:controller.playerIndex]];

        // Re-evaluate the on-screen control mode
        [self updateAutoOnScreenControlMode];
        
        // Notify the delegate
        [self->_presenceDelegate gamepadPresenceChanged];
    }];
    
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        _mouseConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Mouse connected!");
            
            GCMouse* mouse = note.object;
            
            // Register for mouse events
            [self registerMouseCallbacks: mouse];

            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
            
            // Notify the delegate
            [self->_presenceDelegate mousePresenceChanged];
        }];
        _mouseDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Mouse disconnected!");
            
            GCMouse* mouse = note.object;
            
            // Unregister for mouse events
            [self unregisterMouseCallbacks: mouse];

            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
            
            // Notify the delegate
            [self->_presenceDelegate mousePresenceChanged];
        }];
        _keyboardConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Keyboard connected!");
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
        }];
        _keyboardDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Keyboard disconnected!");

            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
        }];
    }
    
    return self;
}

-(void) cleanup
{
    [[NSNotificationCenter defaultCenter] removeObserver:_controllerConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_controllerDisconnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_mouseConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_mouseDisconnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_keyboardConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_keyboardDisconnectObserver];
    
    _controllerConnectObserver = nil;
    _controllerDisconnectObserver = nil;
    _mouseConnectObserver = nil;
    _mouseDisconnectObserver = nil;
    _keyboardConnectObserver = nil;
    _keyboardDisconnectObserver = nil;
    
    _controllerNumbers = 0;
    
    for (Controller* controller in [_controllers allValues]) {
        [self cleanupControllerHaptics:controller];
    }
    [_controllers removeAllObjects];
    
    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            [self unregisterControllerCallbacks:controller];
        }
    }
    
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        for (GCMouse* mouse in [GCMouse mice]) {
            [self unregisterMouseCallbacks:mouse];
        }
    }
}

@end
