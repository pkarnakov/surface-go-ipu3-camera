/*
 * Offline smoke test of intel-ipu3-ipa.so as libcamera 0.5.2 drives it:
 * dlopen, ipaCreate, init/configure/start for the ov5693 at 1296x972, then
 * N rounds of computeParams + processStats with statistics as the hardware
 * returns them (the grid config from the params, no bubbles), data bytes
 * all STATFILL (default 0: black).
 *   STATFILL=64 ipa_smoke MODULE.so [N]
 */
#include <dlfcn.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <memory>

#include <linux/intel-ipu3.h>
#include <linux/v4l2-controls.h>

#include <libcamera/base/shared_fd.h>
#include <libcamera/control_ids.h>
#include <libcamera/controls.h>
#include <libcamera/framebuffer.h>
#include <libcamera/ipa/ipa_module_info.h>
#include <libcamera/ipa/ipu3_ipa_interface.h>

using namespace libcamera;
using namespace libcamera::ipa::ipu3;

static ControlId cExp(V4L2_CID_EXPOSURE, "Exposure", "v4l2", ControlTypeInteger32, ControlId::Direction::In);
static ControlId cGain(V4L2_CID_ANALOGUE_GAIN, "Analogue Gain", "v4l2", ControlTypeInteger32, ControlId::Direction::In);
static ControlId cHbl(V4L2_CID_HBLANK, "Horizontal Blanking", "v4l2", ControlTypeInteger32, ControlId::Direction::In);
static ControlId cVbl(V4L2_CID_VBLANK, "Vertical Blanking", "v4l2", ControlTypeInteger32, ControlId::Direction::In);

struct Receiver {
	int params = 0, metadata = 0, sensor = 0;
	int32_t exp = 0, gain = 0;
	void onParams(unsigned int) { params++; }
	void onMetadata(unsigned int, const ControlList &md)
	{
		metadata++;
		auto fd = md.get(controls::FrameDuration);
		if (metadata == 1 && fd) printf("  metadata: FrameDuration %lld us\n", (long long)*fd);
	}
	void onSensor(unsigned int, const ControlList &s, const ControlList &)
	{
		sensor++;
		exp = s.get(V4L2_CID_EXPOSURE).get<int32_t>();
		gain = s.get(V4L2_CID_ANALOGUE_GAIN).get<int32_t>();
	}
};

static FrameBuffer::Plane plane(size_t size, void **map)
{
	int fd = memfd_create("ipa", 0);
	if (ftruncate(fd, size)) perror("ftruncate");
	*map = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	FrameBuffer::Plane p;
	p.fd = SharedFD(std::move(fd));
	p.offset = 0;
	p.length = size;
	return p;
}

int main(int argc, char **argv)
{
	int rounds = argc > 2 ? atoi(argv[2]) : 10;
	void *h = dlopen(argv[1], RTLD_NOW);
	if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
	auto *info = static_cast<const IPAModuleInfo *>(dlsym(h, "ipaModuleInfo"));
	printf("module: api %u pipeline %u %s %s\n", info->moduleAPIVersion,
	       info->pipelineVersion, info->pipelineName, info->name);
	auto create = reinterpret_cast<IPAInterface *(*)()>(dlsym(h, "ipaCreate"));
	std::unique_ptr<IPAIPU3Interface> ipa(static_cast<IPAIPU3Interface *>(create()));

	Receiver r;
	ipa->paramsComputed.connect(&r, &Receiver::onParams);
	ipa->metadataReady.connect(&r, &Receiver::onMetadata);
	ipa->setSensorControls.connect(&r, &Receiver::onSensor);

	/* ov5693 2x2 binned 1296x972 as on the Surface Go 3 (kernel 7.2) */
	IPACameraSensorInfo si;
	si.model = "ov5693"; si.bitsPerPixel = 10; si.cfaPattern = 0;
	si.activeAreaSize = Size(2592, 1944);
	si.analogCrop = Rectangle(0, 0, 2592, 1944);
	si.outputSize = Size(1296, 972);
	si.pixelRate = 167680000;
	si.minLineLength = si.maxLineLength = 2688;
	si.minFrameLength = 976; si.maxFrameLength = 972 + 63591;

	ControlInfoMap::Map m;
	m.emplace(&cExp, ControlInfo(1, 1976, 1976));
	m.emplace(&cGain, ControlInfo(1, 127, 8));
	m.emplace(&cHbl, ControlInfo(1392, 1392, 1392));
	m.emplace(&cVbl, ControlInfo(4, 63591, 1012));
	static ControlIdMap idmap = { { cExp.id(), &cExp }, { cGain.id(), &cGain },
				      { cHbl.id(), &cHbl }, { cVbl.id(), &cVbl } };
	ControlInfoMap sensorCtrls(std::move(m), idmap);

	ControlInfoMap ipaCtrls;
	int ret = ipa->init(IPASettings("", "ov5693"), si, sensorCtrls, &ipaCtrls);
	printf("init: %d, %zu IPA controls\n", ret, ipaCtrls.size());
	if (ret) return 1;

	IPAConfigInfo ci(si, sensorCtrls, ControlInfoMap(), Size(1280, 720), Size(1296, 972));
	ret = ipa->configure(ci, &ipaCtrls);
	printf("configure: %d\n", ret);
	if (ret) return 1;

	void *pm, *sm;
	std::vector<IPABuffer> bufs;
	bufs.emplace_back(1, std::vector<FrameBuffer::Plane>{ plane(sizeof(ipu3_uapi_params), &pm) });
	bufs.emplace_back(2, std::vector<FrameBuffer::Plane>{ plane(sizeof(ipu3_uapi_stats_3a), &sm) });
	ipa->mapBuffers(bufs);

	ret = ipa->start();
	printf("start: %d, sensor controls: exposure %d lines, gain code %d\n", ret, r.exp, r.gain);

	auto *params = static_cast<ipu3_uapi_params *>(pm);
	for (int f = 1; f <= rounds; f++) {
		ipa->queueRequest(f, ControlList(controls::controls));
		ipa->computeParams(f, 1);
		if (f == 1)
			printf("  params use: acc_iefd %u acc_yds %u acc_anr %u acc_bnr %u acc_tcc %u acc_ccm %u acc_gamma %u acc_awb %u acc_shd %u\n",
			       params->use.acc_iefd, params->use.acc_yds, params->use.acc_anr,
			       params->use.acc_bnr, params->use.acc_tcc, params->use.acc_ccm,
			       params->use.acc_gamma, params->use.acc_awb, params->use.acc_shd);
		ControlList sc(sensorCtrls);
		sc.set(V4L2_CID_EXPOSURE, r.exp);
		sc.set(V4L2_CID_ANALOGUE_GAIN, r.gain);
		/* what the hardware returns: the grid config it ran with, no bubbles, data */
		auto *st = static_cast<ipu3_uapi_stats_3a *>(sm);
		memset(st, 0, sizeof(*st));
		st->stats_4a_config.awb_config = params->acc_param.awb.config;
		st->stats_4a_config.ae_grd_config = params->acc_param.ae.grid_cfg;
		st->stats_4a_config.af_config = params->acc_param.af;
		st->stats_4a_config.awb_fr_config = params->acc_param.awb_fr;
		st->stats_3a_status.awb_en = st->stats_3a_status.ae_en = 1;
		st->stats_3a_status.af_en = st->stats_3a_status.awb_fr_en = 1;
		if (getenv("STATFILL")) {
			int v = atoi(getenv("STATFILL"));
			memset(&st->awb_raw_buffer, v, sizeof(st->awb_raw_buffer));
			memset(&st->ae_raw_buffer, v, sizeof(st->ae_raw_buffer));
			memset(&st->af_raw_buffer, v, sizeof(st->af_raw_buffer));
		}
		if (f == 1)
			printf("  awb grid %ux%u, ae grid %ux%u\n",
			       st->stats_4a_config.awb_config.grid.width, st->stats_4a_config.awb_config.grid.height,
			       st->stats_4a_config.ae_grd_config.width, st->stats_4a_config.ae_grd_config.height);
		ipa->processStats(f, 1000000000LL + f * 33333333LL, 2, sc);
	}
	printf("after %d frames: params %d metadata %d sensor %d; exposure %d lines, gain code %d\n",
	       rounds, r.params, r.metadata, r.sensor, r.exp, r.gain);
	ipa->stop();
	ipa->unmapBuffers({ 1, 2 });
	return 0;
}
