// -----------------------------------------------------------------------------
// Motion Blur Shader for ReShade
// Author: rosie_dog
// Based on  JakobPCoder's LinearMotionBlur.fx
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
    ui_min = 0.1; ui_max = 1.0; ui_step = 0.01;
    ui_tooltip = "Adjusts the length of the motion blur.";
    ui_label = "Blur Length";
    ui_category = "Motion Blur";
> = 0.25;

uniform int UI_BLUR_SAMPLES_MAX < __UNIFORM_SLIDER_INT1
    ui_min = 3; ui_max = 32; ui_step = 1;
    ui_tooltip = "Adjusts the maximum number of samples used for motion blur.";
    ui_label = "Samples";
    ui_category = "Motion Blur";
> = 5;

uniform bool UI_HQ_SAMPLING <
    ui_label = "High Quality Resampling";
    ui_tooltip = "Enables high-quality resampling for improved motion blur.";
    ui_category = "Motion Blur";
> = false;

uniform float UI_DEPTH_THRESHOLD < __UNIFORM_SLIDER_FLOAT1
    ui_min = 0.001; ui_max = 0.1; ui_step = 0.001;
    ui_tooltip = "Depth threshold for the motion blur.";
    ui_label = "Depth Threshold";
    ui_category = "Motion Blur";
> = 0.01;

uniform float UI_GAUSSIAN_SIGMA < __UNIFORM_SLIDER_FLOAT1
    ui_min = 0.1; ui_max = 3.0; ui_step = 0.1;
    ui_tooltip = "Gaussian blur sigma value.";
    ui_label = "Gaussian Sigma";
    ui_category = "Motion Blur";
> = 1.0;

uniform float UI_BILATERAL_DEPTH_SIGMA < __UNIFORM_SLIDER_FLOAT1
    ui_min = 0.001; ui_max = 0.1; ui_step = 0.001;
    ui_tooltip = "Bilateral blur depth sigma value.";
    ui_label = "Bilateral Depth Sigma";
    ui_category = "Motion Blur";
> = 0.01;

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
// Camera View/Projection Matrix
// -----------------------------------------------------------------------------
float4x4 ViewProjectionMatrix <source = "ViewProjection";>;

// -----------------------------------------------------------------------------
// Functions
// -----------------------------------------------------------------------------
float3 ViewPositionFromDepth(float2 uv, float depth, float4x4 invVPMatrix)
{
    float4 clipSpacePosition = float4((uv * 2 - 1) * float2(1, -1), depth * 2 - 1, 1);
    float4 viewSpacePosition = mul(clipSpacePosition, invVPMatrix);
    return viewSpacePosition.xyz / viewSpacePosition.w;
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
    float4x4 invVPMatrix = transpose(ViewProjectionMatrix);
    float3 viewPos = ViewPositionFromDepth(texcoord, depth, invVPMatrix);

    float2 velocity = tex2D(SamplerMotionVectors, texcoord).xy;
    float3 viewSpaceVelocity = float3(velocity.xy, 0) * (viewPos.z * .75);

    float2 blurDist = velocity * frametime * .1 * UI_BLUR_LENGTH;
    float2 sampleDist = blurDist / UI_BLUR_SAMPLES_MAX;
    int halfSamples = UI_BLUR_SAMPLES_MAX / 2;

    float4 summedSamples = 0.0;
    float weightSum = 0.0;

    for (int s = 0; s < UI_BLUR_SAMPLES_MAX; s++)
    {
        float2 newTexCoord = texcoord - sampleDist * (s - halfSamples);
        float newDepth = tex2D(DepthSampler, newTexCoord).r;
        float3 newViewPos = ViewPositionFromDepth(newTexCoord, newDepth, invVPMatrix);

        // Depth comparison to create per-object motion blur
        float depthDifference = length(viewPos - newViewPos);

        if (depthDifference < UI_DEPTH_THRESHOLD)
        {
            // Calculate the Gaussian weight based on the distance from the center sample
            float distanceFactor = abs(s - halfSamples) / float(UI_BLUR_SAMPLES_MAX);
            float gaussianWeight = GaussianWeight(distanceFactor, UI_GAUSSIAN_SIGMA);

            // Calculate the bilateral weight based on the depth difference
            float bilateralWeight = BilateralWeight(depthDifference, UI_BILATERAL_DEPTH_SIGMA);

            float weight = gaussianWeight * bilateralWeight;

            float4 sampleColor = tex2D(samplerColor, newTexCoord);
            if (UI_HQ_SAMPLING)
            {
                // Perform additional sampling for higher quality (optional)
                float4 adjacentSamples[4];
                adjacentSamples[0] = tex2D(samplerColor, newTexCoord + float2(1, 0) / float2(BUFFER_WIDTH, BUFFER_HEIGHT));
                adjacentSamples[1] = tex2D(samplerColor, newTexCoord + float2(-1, 0) / float2(BUFFER_WIDTH, BUFFER_HEIGHT));
                adjacentSamples[2] = tex2D(samplerColor, newTexCoord + float2(0, 1) / float2(BUFFER_WIDTH, BUFFER_HEIGHT));
                adjacentSamples[3] = tex2D(samplerColor, newTexCoord + float2(0, -1) / float2(BUFFER_WIDTH, BUFFER_HEIGHT));

                for (int i = 0; i < 4; i++)
                {
                    sampleColor += adjacentSamples[i] * 0.25;
                }
                sampleColor /= 2.0;
            }

            summedSamples += sampleColor * weight;
            weightSum += weight;
        }
    }

    return weightSum > 0.0001 ? (summedSamples / weightSum) : tex2D(samplerColor, texcoord);
}

technique LinearMotionBlur
{
    pass PassBlur
    {
        VertexShader = PostProcessVS;
        PixelShader = BlurPS;
    }
}

   
