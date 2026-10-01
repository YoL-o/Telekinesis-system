-- Connected Discord-GitHub
-- Telekinesis interaction system.
-- Controls:
--   F            grab the part you're pointing at / drop the held part
--   Left click   throw the held part
--   Scroll wheel pull the held part closer or push it farther away
--   R            rotate the held part 30 degrees around the world Y axis
--   T            rotate the held part 30 degrees around the world X axis (pitch)
--   G            freeze the held part in mid-air and let go of it

local Players = game:GetService("Players") -- Retrieves Players so this LocalScript can access the local player and their character.
local RunService = game:GetService("RunService") -- Retrieves RunService so held-object movement and the visual tether can be updated continuously.
local UserInputService = game:GetService("UserInputService") -- Retrieves UserInputService for keyboard, mouse-button, cursor-position, and scroll-wheel input.
local Workspace = game:GetService("Workspace") -- Retrieves Workspace for camera access, world raycasts, and temporary world-space visuals.

local MAX_INTERACT_DISTANCE = 40 -- Limits targeting to 40 studs so distant objects cannot be grabbed.
local MIN_HOLD_DISTANCE = 4 -- Prevents the held object from being pulled directly into the camera/player.
local MAX_HOLD_DISTANCE = 20 -- Prevents the player from extending a held object excessively far away.
local HOLD_DISTANCE_STEP = 2 -- Changes the requested hold distance by two studs for each scroll-wheel step.
local HOLD_LERP_SPEED = 10 -- Controls how quickly the current hold distance approaches the player's requested distance.
local WALL_BLOCK_MARGIN = 1 -- Keeps a minimum gap when geometry blocks the hold point so the object cannot be positioned directly on the camera.

local HOLD_FORCE_PER_MASS = 220 -- Base force multiplier used with AssemblyMass so AlignPosition remains effective on differently weighted parts.
local HOLD_TORQUE_PER_MASS = 45 -- Base torque multiplier used with AssemblyMass so rotation control scales with object weight.
local THROW_IMPULSE_PER_MASS = 45 -- Scales throwing impulse by AssemblyMass so throw behavior remains more consistent across different masses.
local ROTATE_STEP = math.rad(30) -- Converts the intended 30-degree rotation increment into radians for CFrame rotation calculations.

local FROZEN_ATTRIBUTE = "TelekinesisFrozen" -- Attribute identifies parts anchored by this system so they can still be targeted and unfrozen later.

local TETHER_COLOR = Color3.fromRGB(255, 205, 60) -- Uses the same visual family as the selection highlight so both effects read as one telekinesis system.

local player = Players.LocalPlayer -- Stores the client-owned Player because all input and targeting in this script belong to that player.
local camera = Workspace.CurrentCamera :: Camera -- Stores the active client camera and type-casts it for camera-ray calculations.

local heldPart: BasePart? = nil -- References the object currently controlled by telekinesis; nil means nothing is being held.
local targetPart: BasePart? = nil -- References the valid object currently under the cursor before it is grabbed.

local holdAttachment: Attachment? = nil -- Stores the temporary attachment used as the common control point for the physics constraints.
local alignPosition: AlignPosition? = nil -- Stores the constraint responsible for moving the held object toward the desired world position.
local alignOrientation: AlignOrientation? = nil -- Stores the constraint responsible for maintaining and changing the held object's orientation.
local heldOrientation = CFrame.identity -- Stores rotation independently from the camera so looking around does not unintentionally rotate the held object.

local tetherLine: Part? = nil -- Stores the temporary neon rod used to visually connect the character to the held object.
local tetherRoot: BasePart? = nil -- Caches the character's HumanoidRootPart so the player end of the tether can follow the character efficiently.

local holdDistance = MIN_HOLD_DISTANCE -- Stores the smoothed distance currently being used to position the held object.
local targetHoldDistance = MIN_HOLD_DISTANCE -- Stores the distance requested by scroll input, allowing holdDistance to interpolate toward it.

local destroyingConnection: RBXScriptConnection? = nil -- Stores the held object's Destroying connection so it can be disconnected explicitly during cleanup.

local highlight = Instance.new("Highlight") -- Creates one reusable Highlight instead of creating and destroying a new effect whenever the target changes.
highlight.FillColor = Color3.fromRGB(255, 205, 60) -- Sets the interior selection color for objects that are valid telekinesis targets.
highlight.FillTransparency = 0.7 -- Keeps the target's original appearance visible while still showing that it is selectable.
highlight.OutlineColor = Color3.fromRGB(255, 170, 0) -- Adds a stronger edge color so the selected object's silhouette remains clear.
highlight.Enabled = false -- Starts disabled because the player has not targeted a valid object yet.
highlight.Parent = Workspace -- Keeps the reusable Highlight in the world while Adornee determines which object receives the effect.

local raycastParams = RaycastParams.new() -- Creates shared raycast configuration so targeting and obstruction checks use the same filtering rules.
raycastParams.FilterType = Enum.RaycastFilterType.Exclude -- Makes entries in FilterDescendantsInstances ignored rather than treated as the only valid targets.
raycastParams.IgnoreWater = true -- Prevents terrain water from blocking telekinesis targeting and hold-position obstruction checks.

local function updateRaycastFilter()
	local filter = {} -- Builds a fresh exclusion list because the character and held object can change during gameplay.

	if player.Character then -- Checks that a character currently exists before attempting to exclude it.
		table.insert(filter, player.Character) -- Excludes the entire local character so cursor rays cannot select the player's own body.
	end

	if heldPart then -- Only adds a held object when telekinesis currently controls one.
		table.insert(filter, heldPart) -- Excludes the held object so the wall-check ray can travel past it and detect geometry ahead.
	end

	raycastParams.FilterDescendantsInstances = filter -- Applies the rebuilt exclusions to the shared RaycastParams object.
end

local function setTarget(part: BasePart?)
	if part == targetPart then return end -- Avoids redundant highlight property updates when the aimed object has not changed.

	targetPart = part -- Stores the new candidate so input handling knows which object should be grabbed when F is pressed.
	highlight.Adornee = part -- Redirects the reusable Highlight to the newly targeted BasePart, or clears it when part is nil.
	highlight.Enabled = part ~= nil -- Shows the selection effect only while a valid target exists.
end

local function findAimedPart(): BasePart?
	local mousePosition = UserInputService:GetMouseLocation() -- Reads the cursor's viewport position so targeting follows the player's actual mouse aim.
	local ray = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y) -- Converts the 2D cursor coordinate into a 3D world-space ray from the camera.
	local result = Workspace:Raycast(ray.Origin, ray.Direction * MAX_INTERACT_DISTANCE, raycastParams) -- Tests along the camera ray while enforcing the maximum interaction range and exclusion filter.

	if not result then -- Handles the case where the ray reaches its maximum distance without hitting geometry.
		return nil -- Reports no target so the selection highlight can be cleared.
	end

	local instance = result.Instance -- Extracts the physical instance struck by the raycast for validation.

	if instance:IsA("BasePart") then -- Ensures only physical BaseParts enter the telekinesis system.
		-- Normal anchored map geometry is intentionally rejected because physics constraints cannot move it.
		-- A part anchored by this telekinesis system is the exception: its attribute lets the player select it again and unfreeze it.
		if not instance.Anchored or instance:GetAttribute(FROZEN_ATTRIBUTE) == true then -- Accepts movable physics objects or objects previously frozen by this system.
			return instance -- Returns the validated part for highlighting and possible grabbing.
		end
	end

	return nil -- Rejects unsupported instances and ordinary anchored geometry.
end

local function release(throw: boolean)
	local part = heldPart -- Keeps a local reference because heldPart is cleared during cleanup before an optional throw is applied.

	if not part then -- Makes release safe to call from death, respawn, or destruction cleanup even when nothing is held.
		return -- Stops because there are no telekinesis resources associated with an active object.
	end

	if destroyingConnection then -- Checks whether this held object has an active destruction listener.
		destroyingConnection:Disconnect() -- Disconnects the listener so it cannot remain referenced after the object is released.
		destroyingConnection = nil -- Clears the stored connection to reflect that no destruction listener is active.
	end

	if tetherLine then -- Checks whether a visible tether was successfully created for this hold.
		tetherLine:Destroy() -- Removes the visual immediately when control of the object ends.
		tetherLine = nil -- Clears the reference so later update frames do not attempt to manipulate the destroyed Part.
	end

	tetherRoot = nil -- Removes the cached character root because no tether needs a player endpoint after release.

	if alignPosition then -- Checks that the movement constraint still exists before cleaning it up.
		alignPosition:Destroy() -- Removes telekinetic positional force so normal physics can control the object again.
		alignPosition = nil -- Clears the stored reference after destruction.
	end

	if alignOrientation then -- Checks that the rotational constraint still exists before cleaning it up.
		alignOrientation:Destroy() -- Removes telekinetic rotational control so the object is no longer forced toward heldOrientation.
		alignOrientation = nil -- Clears the stored reference after destruction.
	end

	if holdAttachment then -- Checks for the temporary attachment shared by the two constraints.
		holdAttachment:Destroy() -- Removes the attachment because it is only required while the object is held.
		holdAttachment = nil -- Clears the stored attachment reference after cleanup.
	end

	heldPart = nil -- Marks the telekinesis system as no longer controlling an object.
	updateRaycastFilter() -- Removes the former held object from raycast exclusions now that it can be targeted normally again.

	if throw and part.Parent then -- Applies throw force only when requested and only if the released object still exists in the DataModel.
		local mousePosition = UserInputService:GetMouseLocation() -- Reads the cursor again so the throw follows the player's aim at the exact moment of release.
		local direction = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y).Direction.Unit -- Converts the cursor into a normalized world direction so impulse magnitude is controlled separately.
		part:ApplyImpulse(direction * (part.AssemblyMass * THROW_IMPULSE_PER_MASS)) -- Multiplies impulse by mass so acceleration is more consistent between lighter and heavier objects.
	end
	-- If throw is false, removing the constraints is enough: gravity and the object's existing velocity resume naturally.
end

local function grab(part: BasePart)
	if heldPart or not part.Parent then -- Rejects a second grab while already holding something and rejects parts removed before the input was processed.
		return -- Leaves the current telekinesis state unchanged when the requested grab is invalid.
	end

	heldPart = part -- Establishes this BasePart as the active object used by the update and input handlers.

	if part:GetAttribute(FROZEN_ATTRIBUTE) == true then -- Detects objects that were previously parked in mid-air by freezeHeld.
		part.Anchored = false -- Returns the frozen object to physics so AlignPosition and AlignOrientation can move it again.
		part:SetAttribute(FROZEN_ATTRIBUTE, nil) -- Removes the custom frozen marker now that the object is no longer intentionally anchored.
	end

	holdDistance = math.clamp((camera.CFrame.Position - part.Position).Magnitude, MIN_HOLD_DISTANCE, MAX_HOLD_DISTANCE) -- Starts at the object's current camera distance while enforcing safe minimum and maximum bounds.
	targetHoldDistance = holdDistance -- Matches the requested distance to the starting distance so grabbing does not immediately interpolate somewhere else.
	heldOrientation = part.CFrame.Rotation -- Captures the object's current world rotation so grabbing preserves its orientation instead of snapping it.

	local attachment = Instance.new("Attachment") -- Creates the point through which both alignment constraints apply their forces to the held part.
	attachment.Parent = part -- Parents the attachment to the controlled BasePart because the constraints operate on that object's assembly.

	local align = Instance.new("AlignPosition") -- Creates the physics constraint that moves the object toward the cursor-derived hold position.
	align.Attachment0 = attachment -- Uses the temporary attachment as the point on the held object controlled by the constraint.
	align.Mode = Enum.PositionAlignmentMode.OneAttachment -- Uses a world-space Position target instead of requiring a second attachment.
	align.MaxForce = part.AssemblyMass * HOLD_FORCE_PER_MASS -- Scales available force with assembly mass so heavier objects can still follow the target responsively.
	align.Responsiveness = 35 -- Gives the constraint a responsive pull without replacing Roblox's physics simulation with direct CFrame movement.
	align.Parent = part -- Parents the constraint to the held object so its lifecycle remains associated with the controlled assembly.

	local orient = Instance.new("AlignOrientation") -- Creates the physics constraint responsible for preserving and intentionally changing object rotation.
	orient.Attachment0 = attachment -- Uses the same attachment so position and orientation control act on the same held assembly.
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment -- Targets a world-space CFrame rotation without requiring another attachment.
	orient.MaxTorque = part.AssemblyMass * HOLD_TORQUE_PER_MASS -- Scales available rotational force with mass so larger assemblies remain controllable.
	orient.Responsiveness = 25 -- Uses slightly softer rotational correction to keep rotation stable rather than excessively abrupt.
	orient.CFrame = heldOrientation -- Initializes the constraint with the object's captured rotation so grabbing does not rotate it unexpectedly.
	orient.Parent = part -- Parents the rotational constraint to the object it controls.

	holdAttachment = attachment -- Stores the attachment so release() can destroy it later.
	alignPosition = align -- Stores the position constraint so Heartbeat can continuously update its world target.
	alignOrientation = orient -- Stores the orientation constraint so rotation input can update its target CFrame.

	-- A thin Part is used for the tether instead of a Beam because a Beam behaves like a ribbon and can become difficult to see edge-on.
	-- The tether begins at HumanoidRootPart instead of the camera so it remains visibly separated from the player's viewing ray.
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart? -- Retrieves the current character root if available and narrows its type for position access.

	if root then -- Creates the tether only when a valid character root exists.
		local line = Instance.new("Part") -- Creates a simple world-space rod whose length and CFrame can be updated directly each frame.
		line.Name = "TelekinesisTether" -- Gives the temporary visual a descriptive name for easier inspection while debugging.
		line.Anchored = true -- Prevents physics from moving the visual because its transform is controlled entirely by the script.
		line.CanCollide = false -- Stops the cosmetic tether from physically colliding with characters or world objects.
		line.CanTouch = false -- Prevents the visual from generating unnecessary touch interactions.
		line.CanQuery = false -- Keeps the tether out of raycasts so it cannot interfere with targeting or obstruction detection.
		line.CastShadow = false -- Prevents a purely cosmetic thin rod from creating distracting or unnecessary shadows.
		line.Material = Enum.Material.Neon -- Makes the tether remain visually bright and readable under different lighting conditions.
		line.Color = TETHER_COLOR -- Matches the tether with the telekinesis targeting color defined earlier.
		line.Transparency = 0.4 -- Makes the effect visible without completely obscuring geometry behind it.
		line.Size = Vector3.new(0.08, 0.08, 1) -- Gives the rod a thin cross-section while leaving its Z length available for per-frame scaling.
		line.Parent = Workspace -- Places the visual in 3D space independently from the held object and character hierarchy.

		tetherLine = line -- Stores the created Part so Heartbeat can resize/reposition it and release() can destroy it.
		tetherRoot = root -- Stores the character endpoint used when calculating the tether's position and length.
	end

	destroyingConnection = part.Destroying:Connect(function() -- Watches the controlled object so external deletion cannot leave stale constraints or references behind.
		release(false) -- Performs normal cleanup without attempting to throw an object that is being destroyed.
	end)

	setTarget(nil) -- Clears the targeting highlight because the selected object has transitioned into the held state.
	updateRaycastFilter() -- Adds the held object to raycast exclusions so it cannot block its own obstruction ray.
end

local function rotateHeld(axis: Vector3)
	if not alignOrientation then -- Rotation requires an active AlignOrientation created by grab().
		return -- Ignores rotation input when no object is currently under rotational control.
	end

	heldOrientation = CFrame.fromAxisAngle(axis, ROTATE_STEP) * heldOrientation -- Applies a fixed world-space rotation increment while retaining all previous rotation input.
	alignOrientation.CFrame = heldOrientation -- Sends the updated target rotation to the physics constraint controlling the held object.
end

local function freezeHeld()
	local part = heldPart -- Captures the current object because release() will clear the shared heldPart reference.

	if not part then -- Allows the function to be called safely even when no object is currently held.
		return -- Stops because there is no physical object to freeze.
	end

	part.Anchored = true -- Locks the assembly at its exact current transform so it remains suspended without telekinesis constraints.
	part:SetAttribute(FROZEN_ATTRIBUTE, true) -- Marks the anchored state as originating from this system so targeting logic can distinguish it from normal map geometry.
	release(false) -- Removes constraints and the tether without throwing, leaving the newly anchored object parked in place.
end

RunService.Heartbeat:Connect(function(dt) -- Runs alongside the physics simulation so hold positioning and the visual tether stay continuously synchronized.
	if heldPart then -- Uses the held-object update path while telekinesis is actively controlling a part.
		holdDistance += (targetHoldDistance - holdDistance) * math.min(dt * HOLD_LERP_SPEED, 1) -- Frame-rate-independently eases the current distance toward the scroll-requested distance instead of snapping.

		if alignPosition then -- Ensures the movement constraint still exists before assigning its next world target.
			local mousePosition = UserInputService:GetMouseLocation() -- Reads the latest cursor position so the held object follows current aim.
			local ray = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y) -- Converts that cursor coordinate into the current camera-space aiming ray.
			local direction = ray.Direction.Unit -- Normalizes the direction so multiplying it by a stud distance produces a predictable world offset.

			local blocked = Workspace:Raycast(ray.Origin, direction * holdDistance, raycastParams) -- Checks the path to the intended hold point so solid geometry can stop the object before it passes through.
			local distance = holdDistance -- Starts with the player's requested/smoothed distance and only shortens it when an obstruction is detected.

			if blocked then -- Handles cases where world geometry lies between the camera and intended hold position.
				distance = math.max(blocked.Distance - heldPart.Size.Magnitude / 2, WALL_BLOCK_MARGIN) -- Stops before the hit surface while reserving approximate object space and enforcing a minimum camera margin.
			end

			alignPosition.Position = ray.Origin + direction * distance -- Sets the physics constraint's world target to the unobstructed point along the current aiming ray.
		end

		if tetherLine and tetherRoot then -- Updates the cosmetic connection only when both of its endpoints are still available.
			local playerEnd = tetherRoot.Position -- Reads the current character-root position because the player can move while holding an object.
			local partEnd = heldPart.Position -- Reads the current held-object position after physics movement.
			local length = (partEnd - playerEnd).Magnitude -- Calculates the endpoint separation needed to scale the tether exactly between them.

			tetherLine.Size = Vector3.new(0.08, 0.08, length) -- Resizes the rod along its local Z axis to span the current endpoint distance.
			tetherLine.CFrame = CFrame.lookAt((playerEnd + partEnd) / 2, partEnd) -- Centers the rod halfway between the endpoints and points its Z axis toward the held object.
		end
	else -- Uses targeting behavior instead when no object is currently controlled.
		setTarget(findAimedPart()) -- Raycasts beneath the cursor and updates the reusable highlight only when the valid target changes.
	end
end)

UserInputService.InputBegan:Connect(function(input, processed) -- Handles discrete keyboard and mouse-button actions used by the telekinesis controls.
	if processed then return end -- Ignores input already consumed by Roblox UI, such as typing into chat, so gameplay controls do not fire simultaneously.

	if input.KeyCode == Enum.KeyCode.F then -- Uses F as the toggle between grabbing a target and dropping the current object.
		if heldPart then -- Gives dropping priority when an object is already being controlled.
			release(false) -- Removes telekinesis constraints without adding throw impulse.
		elseif targetPart then -- Allows a grab only when cursor targeting has already found a valid BasePart.
			grab(targetPart) -- Transfers the highlighted target into the held-object state.
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 and heldPart then -- Treats left click as a throw only while an object is currently held.
		release(true) -- Cleans up the hold and applies a mass-scaled impulse along the current cursor direction.
	elseif input.KeyCode == Enum.KeyCode.R then -- Maps R to yaw-style rotation around the world's vertical axis.
		rotateHeld(Vector3.yAxis) -- Adds one ROTATE_STEP around world Y to the stored orientation.
	elseif input.KeyCode == Enum.KeyCode.T then -- Maps T to pitch-style rotation around the world's X axis.
		rotateHeld(Vector3.xAxis) -- Adds one ROTATE_STEP around world X to the stored orientation.
	elseif input.KeyCode == Enum.KeyCode.G then -- Maps G to parking the currently held object in place.
		freezeHeld() -- Anchors and tags the object before releasing the temporary telekinesis resources.
	end
end)

UserInputService.InputChanged:Connect(function(input, processed) -- Handles continuous/change-style input, specifically mouse-wheel movement for hold distance.
	if processed or input.UserInputType ~= Enum.UserInputType.MouseWheel or not heldPart then -- Rejects UI-consumed input, non-wheel changes, and scrolling when nothing is held.
		return -- Leaves the requested hold distance unchanged for irrelevant input.
	end

	targetHoldDistance = math.clamp(targetHoldDistance + input.Position.Z * HOLD_DISTANCE_STEP, MIN_HOLD_DISTANCE, MAX_HOLD_DISTANCE) -- Converts wheel direction into bounded distance changes while Heartbeat handles smooth interpolation.
end)

player.CharacterAdded:Connect(function(character) -- Reinitializes character-dependent telekinesis state whenever the local player respawns.
	release(false) -- Cleans up any object left from the previous character before establishing the new character state.
	setTarget(nil) -- Clears any stale target/highlight selected before the respawn.
	updateRaycastFilter() -- Rebuilds exclusions so future raycasts ignore the newly spawned character model.

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid -- Waits for the new Humanoid and narrows its type so the death event can be connected safely.
	humanoid.Died:Connect(function() -- Watches the current character's lifetime so held physics objects are not left controlled after death.
		release(false) -- Immediately returns any held object to normal physics and removes temporary telekinesis resources.
	end)
end)

updateRaycastFilter() -- Initializes the exclusion list for the character that already exists when this LocalScript first starts.
