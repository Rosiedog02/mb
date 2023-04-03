// -----------------------------------------------------------------------------
// Motion Blur Shader for ReShade
// Author: rosie_dog
// Based on JakobPCoder's LinearMotionBlur.fx
// https://creativecommons.org/licenses/by-nc/4.0/
// https://creativecommons.org/licenses/by-nc/4.0/legalcode
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Includes
// -----------------------------------------------------------------------------
#include "ReShadeUI.fxh"
#include "ReShade.fxh"

// -----------------------------------------------------------------------------
// Frame Time
// -----------------------------------------------------------------------------
uniform float frametime <source = "frametime";>;

// -----------------------------------------------------------------------------
// User Interface
// -----------------------------------------------------------------------------
// Motion Blur Category
uniform float UI_BLUR_LENGTH < __UNIFORM_SLIDER_FLOAT1
    ui_min = 0.1; ui_max = 2.0; ui_step = 0.01;
    ui_tooltip = "Adjusts the length of the motion blur. Higher values result in a longer blur trail, while lower values result in a shorter blur trail.";
    ui_label = "Blur Length";
    ui_category = "Motion Blur";
> = 0.25;

uniform int UI_BLUR_SAMPLES_MAX < __UNIFORM_SLIDER_INT1
    ui_min = 3; ui_max = 32; ui_step = 1;
    ui_tooltip = "Adjusts the maximum number of samples used for motion blur. Higher values provide more accurate blur but may decrease performance. Lower values are faster but may produce less accurate blur.";
    ui_label = "Samples";
    ui_category = "Motion Blur";
> = 5;

uniform bool UI_HQ_SAMPLING <
    ui_label = "High Quality Resampling";
    ui_tooltip = "Enables high-quality resampling for improved motion blur. This option may result in better-looking blur but may also reduce performance.";
    ui_category = "Motion Blur";
> = false;

uniform float UI_DEPTH_THRESHOLD < __UNIFORM_SLIDER_FLOAT1
    ui_min = 0.001; ui_max = 0.1; ui_step = 0.001;
    ui_tooltip = "Depth threshold for the motion blur. Controls the tolerance for depth differences between objects. Lower values result in more accurate per-object blur but may produce artifacts, while higher values result in less accurate per-object blur but reduce artifacts.";
    ui_label = "Depth Threshold";
    ui_category = "Motion Blur";
> = 0.01;

uniform float UI_GAUSSIAN_SIGMA < __UNIFORM_SLIDER_FLOAT1
    ui_min = 0.1; ui_max = 3.0; ui_step = 0.1;
    ui_tooltip = "Gaussian blur sigma value. Controls the smoothness of the motion blur. Higher values result in a smoother blur, while lower values produce a sharper blur.";
    ui_label = "Gaussian Sigma";
    ui_category = "Motion Blur";
> = 1.0;

uniform float UI_BILATERAL_DEPTH_SIGMA < __UNIFORM_SLIDER_FLOAT1
    ui_min = 0.001; ui_max = 0.1; ui_step = 0.001;
    ui_tooltip = "Bilateral blur depth sigma value. Controls the sensitivity of the bilateral filter to depth differences. Lower values result in a sharper depth separation, while higher values produce a smoother depth separation.";
    ui_label = "Bilateral Depth Sigma";
    ui_category = "Motion Blur";
> = 0.01;

// -----------------------------------------------------------------------------
// Camera Properties
// -----------------------------------------------------------------------------
uniform float CameraFOV <
    ui_min = 30.0; ui_max = 120.0; ui_step = 1.0;
    ui_tooltip = "The camera's field of view in degrees. Adjust this to match the in-game camera settings for correct depth calculation.";
    ui_label = "Camera Field of View";
    ui_category = "Motion Blur";
> = 90.0;

uniform float CameraAspectRatio <
    ui_min = 1.0; ui_max = 2.5; ui_step = 0.01;
    ui_tooltip = "The camera's aspect ratio (width / height). Adjust this to match the in-game camera settings for correct depth calculation.";
    ui_label = "Camera Aspect Ratio";
    ui_category = "Motion Blur";
> = 16.0 / 9.0;

// -----------------------------------------------------------------------------
// Textures & Samplers
// -----------------------------------------------------------------------------
texture2D texColor : COLOR;
sampler samplerColor { Texture = texColor; AddressU = Clamp; AddressV = Clamp; MipFilter = Linear; MinFilter = Linear; MagFilter = Linear; };

texture texMotionVectors { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RG16F; };
sampler SamplerMotionVectors { Texture = texMotionVectors; AddressU = Clamp; AddressV = Clamp; MipFilter = Point; MinFilter = Point; MagFilter = Point; };

texture texDepth : DEPTH;
sampler DepthSampler { Texture = texDepth; AddressU = Clamp; AddressV = Clamp; MipFilter = Linear; MinFilter = Linear; MagFilter = Linear; };

// -----------------------------------------------------------------------------
// Functions
// -----------------------------------------------------------------------------
float3 ViewPositionFromDepth(float2 uv, float depth)
{
    float zNear = 0.1;
    float zFar = 1000.0;
    float f = 1.0 / tan(CameraFOV * 0.5 * 3.141592 / 180.0);
    float aspectRatio = CameraAspectRatio;

    float3 ndc = float3(uv * 2.0 - 1.0, depth * 2.0 - 1.0);
    float3 clipSpacePosition = float3(ndc.x / f / aspectRatio, ndc.y / f, ndc.z);
    float linearDepth = zNear / (zFar - clipSpacePosition.z * (zFar - zNear));
    float3 viewSpacePosition = float3(clipSpacePosition.x * linearDepth, clipSpacePosition.y * linearDepth, -linearDepth);
    return viewSpacePosition;
}

float GaussianWeight(float x, float sigma)
{
    return exp(-0.5 * (x * x) / (sigma * sigma)) / (sigma * sqrt(2 * 3.141592));
}

float BilateralWeight(float depthDifference, float sigma)
{
    return exp(-0.5 * (depthDifference * depthDifference) / (sigma * sigma));
}

// -----------------------------------------------------------------------------
// Passes
// -----------------------------------------------------------------------------
float4 BlurPS(float4 position : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float depth = tex2D(DepthSampler, texcoord).r;
    float3 viewPos = ViewPositionFromDepth(texcoord, depth);

    float2 velocity = tex2D(SamplerMotionVectors, texcoord).xy;
    float3 viewSpaceVelocity = float3(velocity.xy, 0) * (viewPos.z * .75);
    float2 blurDist = velocity * frametime * .1 * UI_BLUR_LENGTH;
    float2 sampleDist = blurDist / UI_BLUR_SAMPLES_MAX;
    int halfSamples = UI_BLUR_SAMPLES_MAX / 2;

    float4 summedSamples = 0.0;
    float weightSum = 0.0;

    for (int i = -halfSamples; i <= halfSamples; ++i)
    {
        float2 sampleOffset = float2(i, 0) * sampleDist;
        float2 sampleTexCoord = texcoord + sampleOffset;

        float sampleDepth = tex2D(DepthSampler, sampleTexCoord).r;
        float3 sampleViewPos = ViewPositionFromDepth(sampleTexCoord, sampleDepth);
        float depthDifference = length(sampleViewPos - viewPos);

        float gaussianWeight = GaussianWeight(i, UI_GAUSSIAN_SIGMA);
        float bilateralWeight = BilateralWeight(depthDifference, UI_BILATERAL_DEPTH_SIGMA);

        float totalWeight = gaussianWeight * bilateralWeight;

        float4 sampleColor = tex2D(samplerColor, sampleTexCoord);
        summedSamples += sampleColor * totalWeight;
        weightSum += totalWeight;
    }

    return summedSamples / weightSum;
}

technique MotionBlur 
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = BlurPS;
    }
}
