-- Connected Discord-GitHub
-- Telekinesis interaction system.
-- Controls:
--   F            grab the part you're pointing at / drop the held part
--   Left click   throw the held part
--   Scroll wheel pull the held part closer or push it farther away
--   R            rotate the held part 30 degrees around the world Y axis 
--   T            rotate the held part 30 degrees around the world X axis (pitch)
--   G            freeze the held part in mid-air and let go of it

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local MAX_INTERACT_DISTANCE = 40
local MIN_HOLD_DISTANCE = 4
local MAX_HOLD_DISTANCE = 20
local HOLD_DISTANCE_STEP = 2
local HOLD_LERP_SPEED = 10 
local WALL_BLOCK_MARGIN = 1 -- closest the held part can sit to the camera when a wall blocks it, so it never ends up inside your head

local HOLD_FORCE_PER_MASS = 220 
local HOLD_TORQUE_PER_MASS = 45
local THROW_IMPULSE_PER_MASS = 45
local ROTATE_STEP = math.rad(30)

local FROZEN_ATTRIBUTE = "TelekinesisFrozen" -- tag put on frozen parts so we can tell them apart from normal anchored geometry

local TETHER_COLOR = Color3.fromRGB(255, 205, 60) -- matches the highlight so the tether reads as the same effect

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera :: Camera

local heldPart: BasePart? = nil
local targetPart: BasePart? = nil

local holdAttachment: Attachment? = nil
local alignPosition: AlignPosition? = nil
local alignOrientation: AlignOrientation? = nil
local heldOrientation = CFrame.identity -- Stored separately so the object keeps its rotation even if the player moves the camera.

local tetherLine: Part? = nil -- thin neon rod stretched between player and held part as the visible tether
local tetherRoot: BasePart? = nil -- cached HumanoidRootPart so the tether's player end follows the character

local holdDistance = MIN_HOLD_DISTANCE
local targetHoldDistance = MIN_HOLD_DISTANCE

local destroyingConnection: RBXScriptConnection? = nil

local highlight = Instance.new("Highlight")
highlight.FillColor = Color3.fromRGB(255, 205, 60)
highlight.FillTransparency = 0.7
highlight.OutlineColor = Color3.fromRGB(255, 170, 0)
highlight.Enabled = false
highlight.Parent = Workspace

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude -- Tells the raycast to ignore the specific parts we add to the filter list.
raycastParams.IgnoreWater = true

local function updateRaycastFilter()
	local filter = {}
	if player.Character then
		table.insert(filter, player.Character)
	end
	if heldPart then
		table.insert(filter, heldPart)
	end
	raycastParams.FilterDescendantsInstances = filter -- Applies the list so the ray won't hit the player's body or the object they are holding.
end

local function setTarget(part: BasePart?)
	if part == targetPart then return end -- Early return to save performance if the cursor hasn't moved to a new object.
	targetPart = part
	highlight.Adornee = part -- Attaches the visual highlight effect to the 3D part in the world.
	highlight.Enabled = part ~= nil
end

local function findAimedPart(): BasePart?
	local mousePosition = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y) -- Converts 2D screen coordinates into a 3D ray for accurate mouse aiming.
	local result = Workspace:Raycast(ray.Origin, ray.Direction * MAX_INTERACT_DISTANCE, raycastParams) -- Casts the ray into the world to find physical objects.
	if not result then
		return nil
	end

	local instance = result.Instance
	if instance:IsA("BasePart") then
		-- anchored geometry is normally skipped since it can't be picked up, but parts we froze
		-- ourselves carry the frozen tag, so they stay grabbable in order to unfreeze them
		if not instance.Anchored or instance:GetAttribute(FROZEN_ATTRIBUTE) == true then
			return instance
		end
	end
	return nil
end

local function release(throw: boolean)
	local part = heldPart
	if not part then
		return
	end

	if destroyingConnection then
		destroyingConnection:Disconnect() -- Stops listening to the destroy event to prevent memory leaks.
		destroyingConnection = nil
	end

	if tetherLine then
		tetherLine:Destroy() -- Remove the visual tether straight away so it doesn't flash for a frame after letting go.
		tetherLine = nil
	end
	tetherRoot = nil

	if alignPosition then
		alignPosition:Destroy() -- Removes the physics constraint so the object falls naturally.
		alignPosition = nil
	end
	if alignOrientation then
		alignOrientation:Destroy()
		alignOrientation = nil
	end
	if holdAttachment then
		holdAttachment:Destroy()
		holdAttachment = nil
	end

	heldPart = nil
	updateRaycastFilter()

	if throw and part.Parent then
		local mousePosition = UserInputService:GetMouseLocation()
		local direction = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y).Direction.Unit
		part:ApplyImpulse(direction * (part.AssemblyMass * THROW_IMPULSE_PER_MASS)) -- Applies a physical force scaled by mass so heavy objects throw just as far as light ones.
	end
	-- when throw is false this acts as a plain drop: constraints are gone and gravity takes over
end

local function grab(part: BasePart)
	if heldPart or not part.Parent then
		return
	end

	heldPart = part
	if part:GetAttribute(FROZEN_ATTRIBUTE) == true then
		part.Anchored = false -- unfreeze: hand the part back to physics so the hold constraints can move it again
		part:SetAttribute(FROZEN_ATTRIBUTE, nil)
	end
	holdDistance = math.clamp((camera.CFrame.Position - part.Position).Magnitude, MIN_HOLD_DISTANCE, MAX_HOLD_DISTANCE) -- Limits the starting distance so the object doesn't snap too close or too far.
	targetHoldDistance = holdDistance
	heldOrientation = part.CFrame.Rotation

	local attachment = Instance.new("Attachment")
	attachment.Parent = part

	local align = Instance.new("AlignPosition")
	align.Attachment0 = attachment
	align.Mode = Enum.PositionAlignmentMode.OneAttachment -- Tells the constraint to pull the part toward a raw world coordinate instead of another part.
	align.MaxForce = part.AssemblyMass * HOLD_FORCE_PER_MASS -- Scales the pulling force based on weight so heavy objects don't lag behind.
	align.Responsiveness = 35
	align.Parent = part

	local orient = Instance.new("AlignOrientation")
	orient.Attachment0 = attachment
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment -- Locks the rotation in world space so it doesn't spin when the player looks around.
	orient.MaxTorque = part.AssemblyMass * HOLD_TORQUE_PER_MASS
	orient.Responsiveness = 25
	orient.CFrame = heldOrientation
	orient.Parent = part

	holdAttachment = attachment
	alignPosition = align
	alignOrientation = orient

	-- the tether is a thin cylinder instead of a Beam: a beam is a flat ribbon that can turn
	-- edge-on and disappear, and a line from the camera would point straight down the view ray,
	-- so we stretch it from the character's root part to the part where it stays visible from every angle
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		local line = Instance.new("Part")
		line.Name = "TelekinesisTether"
		line.Anchored = true -- moved by CFrame only, physics must never push the tether around
		line.CanCollide = false
		line.CanTouch = false
		line.CanQuery = false -- keeps the tether out of our own raycasts so it can't block grabs or wall checks
		line.CastShadow = false
		line.Material = Enum.Material.Neon -- neon ignores lighting so the tether glows even in dark rooms
		line.Color = TETHER_COLOR
		line.Transparency = 0.4 -- slightly see-through so it doesn't hide the object behind it
		line.Size = Vector3.new(0.08, 0.08, 1) -- thin rod; the length is rescaled every frame in Heartbeat
		line.Parent = Workspace

		tetherLine = line
		tetherRoot = root
	end

	destroyingConnection = part.Destroying:Connect(function() -- Cleans up constraints automatically if the object is deleted while held.
		release(false)
	end)

	setTarget(nil)
	updateRaycastFilter()
end

local function rotateHeld(axis: Vector3)
	if not alignOrientation then
		return
	end
	heldOrientation = CFrame.fromAxisAngle(axis, ROTATE_STEP) * heldOrientation -- Multiplies the new rotation in world space to prevent the object from spinning relative to its own axes.
	alignOrientation.CFrame = heldOrientation
end

local function freezeHeld()
	local part = heldPart
	if not part then
		return
	end
	-- anchoring locks the part dead in mid-air at its exact position and orientation,
	-- so it keeps floating with no constraints or tether needed to hold it up
	part.Anchored = true
	part:SetAttribute(FROZEN_ATTRIBUTE, true) -- tag it so findAimedPart still sees it later for unfreezing
	release(false) -- cut the telekinesis link: tether and constraints are torn down while the anchored part stays put
end

RunService.Heartbeat:Connect(function(dt)
	if heldPart then
		holdDistance += (targetHoldDistance - holdDistance) * math.min(dt * HOLD_LERP_SPEED, 1) -- Smoothly interpolates the distance over time instead of snapping instantly.
		if alignPosition then
			local mousePosition = UserInputService:GetMouseLocation()
			local ray = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)
			local direction = ray.Direction.Unit
			-- cast ahead to the hold point with the same filter, so walls and props block the object instead of letting it drag through them
			local blocked = Workspace:Raycast(ray.Origin, direction * holdDistance, raycastParams)
			local distance = holdDistance
			if blocked then
				-- stop short of the surface, leaving room for half the part's size so it rests against the wall instead of sinking into it
				distance = math.max(blocked.Distance - heldPart.Size.Magnitude / 2, WALL_BLOCK_MARGIN)
			end
			-- holdDistance keeps the player's wanted distance, so the part slides back out to it once the wall is gone
			alignPosition.Position = ray.Origin + direction * distance
		end
		if tetherLine and tetherRoot then
			local playerEnd = tetherRoot.Position
			local partEnd = heldPart.Position
			-- rescale and re-aim the rod every frame so it always spans character to held part
			tetherLine.Size = Vector3.new(0.08, 0.08, (partEnd - playerEnd).Magnitude)
			tetherLine.CFrame = CFrame.lookAt((playerEnd + partEnd) / 2, partEnd) -- lookAt aims the rod's length axis along the line between the two ends
		end
	else
		setTarget(findAimedPart())
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end -- Ignores inputs if a UI element like the chat box is currently using them.

	if input.KeyCode == Enum.KeyCode.F then
		if heldPart then
			release(false) -- Drop: let go without any extra force.
		elseif targetPart then
			grab(targetPart)
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 and heldPart then
		release(true) -- Throw: let go and push it along the camera ray.
	elseif input.KeyCode == Enum.KeyCode.R then
		rotateHeld(Vector3.yAxis)
	elseif input.KeyCode == Enum.KeyCode.T then
		rotateHeld(Vector3.xAxis)
	elseif input.KeyCode == Enum.KeyCode.G then
		freezeHeld() -- park the part in mid-air and cut the telekinesis link
	end
end)

UserInputService.InputChanged:Connect(function(input, processed)
	if processed or input.UserInputType ~= Enum.UserInputType.MouseWheel or not heldPart then
		return
	end
	targetHoldDistance = math.clamp(targetHoldDistance + input.Position.Z * HOLD_DISTANCE_STEP, MIN_HOLD_DISTANCE, MAX_HOLD_DISTANCE) -- Uses the Z-axis of the mouse wheel delta to detect scroll direction and keeps it within limits.
end)

player.CharacterAdded:Connect(function(character)
	-- runs on respawn: drop whatever was held so the old constraints don't pull toward a dead character
	release(false)
	setTarget(nil)
	updateRaycastFilter()

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid -- Waits for the character to load and type-casts it for strict mode safety.
	humanoid.Died:Connect(function()
		release(false) -- Drops the object immediately when the player dies to prevent physics glitches.
	end)
end)

updateRaycastFilter()
