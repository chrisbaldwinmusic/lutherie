// Lutherie VST3: a single-component effect that hands audio, parameters, state and the editor
// to the shared Swift engine (libPedalVSTBridge) through a small C interface.

#include "public.sdk/source/vst/vstsinglecomponenteffect.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ustring.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/vsttypes.h"
#include "public.sdk/source/common/pluginview.h"
#include "public.sdk/source/main/pluginfactory.h"
#include "public.sdk/source/vst/vstparameters.h"

#include <cstring>
#include <vector>

extern "C" {
typedef void (*PedalParamCallback)(void* ctx, int32_t id, float value);
void* pedal_create(double sampleRate);
void pedal_destroy(void* p);
void pedal_set_callback(void* p, PedalParamCallback cb, void* ctx);
void pedal_set_sample_rate(void* p, double sr);
void pedal_process(void* p, const float* in, float* out, int32_t frames);
void pedal_set_param(void* p, int32_t id, float v);
float pedal_get_param(void* p, int32_t id);
int32_t pedal_get_latency(void* p);
int32_t pedal_param_count(void);
void pedal_param_info(int32_t index, int32_t* id, char* name, int32_t nameCap, float* minV, float* maxV, float* def,
                      int32_t* steps, char* unit);
int32_t pedal_get_state(void* p, uint8_t* buf, int32_t cap);
void pedal_set_state(void* p, const uint8_t* buf, int32_t len);
void pedal_attach_view(void* p, void* parent);
void pedal_detach_view(void* p);
}

using namespace Steinberg;
using namespace Steinberg::Vst;

static const FUID kLutherieUID(0x32F09484, 0xAF136FE2, 0x1C012B39, 0x2744EF8D);

class LutherieEffect;

class LutherieView : public CPluginView {
public:
    explicit LutherieView(void* engine) : CPluginView(new ViewRect(0, 0, 1280, 820)), engine(engine) {}
    tresult PLUGIN_API isPlatformTypeSupported(FIDString type) SMTG_OVERRIDE {
        return strcmp(type, kPlatformTypeNSView) == 0 ? kResultTrue : kResultFalse;
    }
    tresult PLUGIN_API attached(void* parent, FIDString type) SMTG_OVERRIDE {
        if (strcmp(type, kPlatformTypeNSView) != 0) return kResultFalse;
        CPluginView::attached(parent, type);
        pedal_attach_view(engine, parent);
        return kResultOk;
    }
    tresult PLUGIN_API removed() SMTG_OVERRIDE {
        pedal_detach_view(engine);
        return CPluginView::removed();
    }
    tresult PLUGIN_API canResize() SMTG_OVERRIDE { return kResultTrue; }
    tresult PLUGIN_API checkSizeConstraint(ViewRect* r) SMTG_OVERRIDE {
        if (r->getWidth() < 1000) r->right = r->left + 1000;
        if (r->getHeight() < 680) r->bottom = r->top + 680;
        return kResultTrue;
    }

private:
    void* engine;
};

class LutherieEffect : public SingleComponentEffect {
public:
    static FUnknown* createInstance(void*) { return (IAudioProcessor*)new LutherieEffect; }

    tresult PLUGIN_API initialize(FUnknown* context) SMTG_OVERRIDE {
        tresult r = SingleComponentEffect::initialize(context);
        if (r != kResultOk) return r;
        addAudioInput(STR16("Stereo In"), SpeakerArr::kStereo);
        addAudioOutput(STR16("Stereo Out"), SpeakerArr::kStereo);
        engine = pedal_create(48000.0);
        pedal_set_callback(engine, &LutherieEffect::fromEditor, this);
        int32_t count = pedal_param_count();
        for (int32_t i = 0; i < count; i++) {
            int32_t id, steps;
            char name[128], unit[16];
            float lo, hi, def;
            pedal_param_info(i, &id, name, sizeof(name), &lo, &hi, &def, &steps, unit);
            String128 title, units;
            UString(title, 128).fromAscii(name);
            UString(units, 128).fromAscii(unit);
            auto* p = new RangeParameter(title, id, units, lo, hi, def, steps,
                                         ParameterInfo::kCanAutomate | (steps > 0 ? ParameterInfo::kIsList : 0));
            parameters.addParameter(p);
        }
        return kResultOk;
    }

    tresult PLUGIN_API terminate() SMTG_OVERRIDE {
        if (engine) { pedal_destroy(engine); engine = nullptr; }
        return SingleComponentEffect::terminate();
    }

    tresult PLUGIN_API setBusArrangements(SpeakerArrangement* inputs, int32 numIns, SpeakerArrangement* outputs, int32 numOuts) SMTG_OVERRIDE {
        if (numIns == 1 && numOuts == 1 && SpeakerArr::getChannelCount(inputs[0]) <= 2 && SpeakerArr::getChannelCount(outputs[0]) <= 2)
            return SingleComponentEffect::setBusArrangements(inputs, numIns, outputs, numOuts);
        return kResultFalse;
    }

    uint32 PLUGIN_API getLatencySamples() SMTG_OVERRIDE { return engine ? (uint32)pedal_get_latency(engine) : 0; }

    tresult PLUGIN_API canProcessSampleSize(int32 size) SMTG_OVERRIDE { return size == kSample32 ? kResultTrue : kResultFalse; }

    tresult PLUGIN_API setupProcessing(ProcessSetup& setup) SMTG_OVERRIDE {
        mono.assign(std::max<int32>(setup.maxSamplesPerBlock, 4096), 0.f);
        pedal_set_sample_rate(engine, setup.sampleRate);
        return SingleComponentEffect::setupProcessing(setup);
    }

    tresult PLUGIN_API process(ProcessData& data) SMTG_OVERRIDE {
        if (data.inputParameterChanges) {
            int32 n = data.inputParameterChanges->getParameterCount();
            for (int32 i = 0; i < n; i++) {
                IParamValueQueue* q = data.inputParameterChanges->getParameterData(i);
                if (!q || q->getPointCount() == 0) continue;
                int32 offset;
                ParamValue value;
                if (q->getPoint(q->getPointCount() - 1, offset, value) == kResultTrue) {
                    if (Parameter* p = parameters.getParameter(q->getParameterId()))
                        pedal_set_param(engine, (int32_t)q->getParameterId(), (float)p->toPlain(value));
                }
            }
        }
        if (data.numSamples <= 0 || data.numInputs == 0 || data.numOutputs == 0) return kResultOk;
        const int32 frames = data.numSamples;
        if ((int32)mono.size() < frames) return kResultOk;
        AudioBusBuffers& in = data.inputs[0];
        AudioBusBuffers& out = data.outputs[0];
        const int32 nIn = in.numChannels, nOut = out.numChannels;
        for (int32 f = 0; f < frames; f++) {
            float s = 0;
            for (int32 c = 0; c < nIn; c++) s += in.channelBuffers32[c][f];
            mono[f] = nIn > 0 ? s / (float)nIn : 0.f;
        }
        pedal_process(engine, mono.data(), mono.data(), frames);
        for (int32 c = 0; c < nOut; c++) std::memcpy(out.channelBuffers32[c], mono.data(), sizeof(float) * frames);
        out.silenceFlags = 0;
        return kResultOk;
    }

    tresult PLUGIN_API getState(IBStream* state) SMTG_OVERRIDE {
        int32_t len = pedal_get_state(engine, nullptr, 0);
        std::vector<uint8_t> buf(len);
        pedal_get_state(engine, buf.data(), len);
        int32 written = 0;
        state->write(&len, sizeof(len), &written);
        if (len > 0) state->write(buf.data(), len, &written);
        return kResultOk;
    }

    tresult PLUGIN_API setState(IBStream* state) SMTG_OVERRIDE {
        int32_t len = 0;
        int32 read = 0;
        if (state->read(&len, sizeof(len), &read) != kResultOk || read != sizeof(len) || len < 0 || len > 64 * 1024 * 1024)
            return kResultFalse;
        std::vector<uint8_t> buf(len);
        if (len > 0 && (state->read(buf.data(), len, &read) != kResultOk || read != len)) return kResultFalse;
        if (len > 0) pedal_set_state(engine, buf.data(), len);
        for (int32 i = 0; i < parameters.getParameterCount(); i++) {
            Parameter* p = parameters.getParameterByIndex(i);
            SingleComponentEffect::setParamNormalized(p->getInfo().id, p->toNormalized(pedal_get_param(engine, p->getInfo().id)));
        }
        return kResultOk;
    }

    tresult PLUGIN_API setParamNormalized(ParamID tag, ParamValue value) SMTG_OVERRIDE {
        tresult r = SingleComponentEffect::setParamNormalized(tag, value);
        if (Parameter* p = parameters.getParameter(tag)) pedal_set_param(engine, (int32_t)tag, (float)p->toPlain(value));
        return r;
    }

    IPlugView* PLUGIN_API createView(FIDString name) SMTG_OVERRIDE {
        if (name && strcmp(name, ViewType::kEditor) == 0) return new LutherieView(engine);
        return nullptr;
    }

    // Called by the Swift editor (main thread) when a knob moves, so the host can record automation.
    static void fromEditor(void* ctx, int32_t id, float plain) {
        auto* self = static_cast<LutherieEffect*>(ctx);
        if (id < 0) {  // the delay through the plugin changed: the host re-reads getLatencySamples()
            if (IComponentHandler* h = self->getComponentHandler()) h->restartComponent(kLatencyChanged);
            return;
        }
        Parameter* p = self->parameters.getParameter((ParamID)id);
        if (!p) return;
        ParamValue norm = p->toNormalized(plain);
        self->SingleComponentEffect::setParamNormalized((ParamID)id, norm);
        self->beginEdit((ParamID)id);
        self->performEdit((ParamID)id, norm);
        self->endEdit((ParamID)id);
    }

private:
    void* engine = nullptr;
    std::vector<float> mono;
};

BEGIN_FACTORY_DEF("Channel Audio", "https://example.com", "")
DEF_CLASS2(INLINE_UID_FROM_FUID(kLutherieUID), PClassInfo::kManyInstances, kVstAudioEffectClass, "Lutherie", 0,
           "Fx|Distortion", "1.0.0", kVstVersionString, LutherieEffect::createInstance)
END_FACTORY
